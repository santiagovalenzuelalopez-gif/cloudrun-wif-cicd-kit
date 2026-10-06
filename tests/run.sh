#!/usr/bin/env bash
# Pruebas de scripts/wif-setup.sh contra un gcloud falso (tests/bin/gcloud). No necesita GCP.
#   bash tests/run.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wif-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="demo-project"
ORG="11111111-2222-3333-4444-555555555555"
NUMBER="123456789012"
SUBJECT="sc://acme/Mi Proyecto/gcp-conn"
FED="ado-deployer@${PROJECT}.iam.gserviceaccount.com"
BUILD="cloudbuild-deployer@${PROJECT}.iam.gserviceaccount.com"
RUNTIME="cloudrun-runtime@${PROJECT}.iam.gserviceaccount.com"
POOLPATH="projects/${NUMBER}/locations/global/workloadIdentityPools/ado-pool"
principal() { echo "principal://iam.googleapis.com/${POOLPATH}/subject/$1"; }

PASSED=0; FAILED=0
OUT=""; CODE=0

# ---------------------------------------------------------------- mundos
empty_world() {  # el proyecto existe, no hay nada más
  local w="$TMP/$1"; rm -rf "$w"; mkdir -p "$w/sa_policy" "$w/project_roles" "$w/keys"
  echo "dev@example.com" > "$w/account"
  echo "$NUMBER" > "$w/project_number"
  echo "$w"
}

compliant_world() {  # todo configurado como lo deja 'apply'
  local w; w="$(empty_world "$1")"
  printf '%s\n' sts.googleapis.com iamcredentials.googleapis.com iam.googleapis.com cloudbuild.googleapis.com \
    run.googleapis.com storage.googleapis.com artifactregistry.googleapis.com > "$w/apis_enabled"
  printf '%s\n' "$FED" "$BUILD" "$RUNTIME" > "$w/sa_exists"
  touch "$w/pool" "$w/bucket" "$w/ar"
  echo ACTIVE > "$w/provider_state"
  echo "https://vstoken.dev.azure.com/${ORG}" > "$w/provider_issuer"
  echo "api://AzureADTokenExchange" > "$w/provider_audience"
  echo "google.subject=assertion.sub" > "$w/provider_mapping"
  echo "assertion.sub == '${SUBJECT}'" > "$w/provider_condition"
  echo "roles/iam.workloadIdentityUser|$(principal "$SUBJECT")" > "$w/sa_policy/$FED"
  echo "roles/iam.serviceAccountUser|serviceAccount:${FED}" > "$w/sa_policy/$BUILD"
  echo "roles/iam.serviceAccountUser|serviceAccount:${BUILD}" > "$w/sa_policy/$RUNTIME"
  echo "roles/cloudbuild.builds.editor" > "$w/project_roles/$FED"
  printf '%s\n' roles/run.developer roles/logging.logWriter > "$w/project_roles/$BUILD"
  : > "$w/keys/$FED"
  printf '%s\n' "roles/storage.objectAdmin|serviceAccount:${FED}" "roles/storage.legacyBucketReader|serviceAccount:${FED}" \
    "roles/storage.objectViewer|serviceAccount:${BUILD}" > "$w/bucket_policy"
  echo "roles/artifactregistry.writer|serviceAccount:${BUILD}" > "$w/ar_policy"
  echo "trigger-1" > "$w/triggers"
  echo "$w"
}

# ---------------------------------------------------------------- ejecución y aserciones
run_script() {  # run_script <mundo> <args...>   (variables extra: EXTRA_ENV="K=v K2=v2")
  local w="$1"; shift
  # shellcheck disable=SC2086
  OUT="$(env WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="$PROJECT" ADO_ORG_ID="$ORG" \
        ADO_SUBJECTS="${SUBJECTS_OVERRIDE:-$SUBJECT}" ${EXTRA_ENV:-} bash "$SCRIPT" "$@" 2>&1)"
  CODE=$?
}

ok_() { PASSED=$((PASSED+1)); echo "  ok   - $1"; }
ko_() { FAILED=$((FAILED+1)); echo "  FAIL - $1"; echo "$2" | sed 's/^/         /' | head -25; }

t_code()   { if [ "$CODE" -eq "$2" ]; then ok_ "$1"; else ko_ "$1 (código $CODE, esperado $2)" "$OUT"; fi; }
t_nonzero(){ if [ "$CODE" -ne 0 ]; then ok_ "$1"; else ko_ "$1 (salió con 0)" "$OUT"; fi; }
t_has()    { if grep -qF -- "$2" <<< "$OUT"; then ok_ "$1"; else ko_ "$1 (falta: $2)" "$OUT"; fi; }
t_hasnt()  { if grep -qF -- "$2" <<< "$OUT"; then ko_ "$1 (no debía aparecer: $2)" "$OUT"; else ok_ "$1"; fi; }
t_no_mutations() {
  if [ -s "$2/mutations.log" ]; then ko_ "$1 (hubo cambios)" "$(cat "$2/mutations.log")"; else ok_ "$1"; fi
}

section() { echo; echo "# $*"; }

# ================================================================ verify
section "verify: configuración conforme"
w="$(compliant_world ok)"
run_script "$w" verify
t_code "termina con código 0" 0
t_has  "FAIL=0" "FAIL=0"
t_no_mutations "no modifica nada" "$w"

w="$(compliant_world crlf)"; touch "$w/crlf"
run_script "$w" verify
t_code "tolera la salida CRLF de gcloud en Windows" 0

section "verify: detecta configuraciones peligrosas"
w="$(compliant_world wildcard)"
echo "roles/iam.workloadIdentityUser|principalSet://iam.googleapis.com/${POOLPATH}/*" >> "$w/sa_policy/$FED"
run_script "$w" verify
t_code "binding comodín del pool -> falla" 1
t_has  "lo señala como principalSet" "principalSet"

w="$(compliant_world prefix-binding)"
echo "roles/iam.workloadIdentityUser|$(principal "sc://acme/Otro Proyecto/otra-conn")" >> "$w/sa_policy/$FED"
run_script "$w" verify
t_code "subject de más (otro proyecto/conexión) -> falla" 1

w="$(compliant_world extra-role)"
printf '%s\n' roles/cloudbuild.builds.editor roles/run.admin > "$w/project_roles/$FED"
run_script "$w" verify
t_code "rol de proyecto de más (run.admin) -> falla" 1
t_has  "indica los roles inesperados" "Roles de proyecto inesperados"

w="$(compliant_world extra-sa-role)"
echo "roles/iam.serviceAccountTokenCreator|user:alguien@example.com" >> "$w/sa_policy/$FED"
run_script "$w" verify
t_code "rol ajeno a la federación sobre la SA federada -> falla" 1

w="$(compliant_world active-key)"
printf 'abc123\tFalse\n' > "$w/keys/$FED"
run_script "$w" verify
t_code "llave de usuario ACTIVA -> falla" 1
t_has  "lo indica" "Llave de usuario ACTIVA"

w="$(compliant_world disabled-key)"
printf 'abc123\tTrue\n' > "$w/keys/$FED"
run_script "$w" verify
t_code "llave deshabilitada -> solo advertencia" 0
t_has  "advierte que hay que borrarla" "DESHABILITADA"

w="$(compliant_world wrong-issuer)"
echo "https://issuer.malicioso.example/${ORG}" > "$w/provider_issuer"
run_script "$w" verify
t_code "issuer inesperado -> falla" 1

w="$(compliant_world wide-condition)"
echo "assertion.sub.startsWith('sc://acme/')" > "$w/provider_condition"
run_script "$w" verify
t_code "condición por prefijo (no exacta) -> falla" 1
t_has  "lo indica" "Condición inesperada"

w="$(compliant_world no-attribute-condition)"
: > "$w/provider_condition"
run_script "$w" verify
t_code "provider SIN condición (cualquier token del issuer) -> falla" 1

w="$(compliant_world no-actas)"
: > "$w/sa_policy/$BUILD"
run_script "$w" verify
t_code "sin serviceAccountUser sobre la SA del build -> falla" 1

w="$(compliant_world no-viewer)"
grep -v objectViewer "$w/bucket_policy" > "$w/bp" && mv "$w/bp" "$w/bucket_policy"
run_script "$w" verify
t_code "la SA del build no puede leer el tarball -> falla" 1
t_has  "indica el permiso faltante" "storage.objectViewer"

w="$(compliant_world public-bucket)"
echo "roles/storage.objectViewer|allUsers" >> "$w/bucket_policy"
run_script "$w" verify
t_code "bucket de staging público -> falla" 1

w="$(compliant_world fed-on-registry)"
echo "roles/artifactregistry.admin|serviceAccount:${FED}" >> "$w/ar_policy"
run_script "$w" verify
t_code "la SA federada con acceso al registro -> falla" 1

w="$(compliant_world pool-wide-on-build)"
echo "roles/iam.workloadIdentityUser|principalSet://iam.googleapis.com/${POOLPATH}/*" >> "$w/sa_policy/$BUILD"
run_script "$w" verify
t_code "principalSet del pool sobre OTRA SA (build) -> falla" 1

section "verify: varios subjects (una conexión por proyecto de ADO)"
S2="sc://acme/Segundo Proyecto/gcp-conn"
w="$(compliant_world two)"
{ echo "roles/iam.workloadIdentityUser|$(principal "$SUBJECT")"; echo "roles/iam.workloadIdentityUser|$(principal "$S2")"; } > "$w/sa_policy/$FED"
echo "assertion.sub in ['${SUBJECT}', '${S2}']" > "$w/provider_condition"
SUBJECTS_OVERRIDE="${SUBJECT};${S2}" run_script "$w" verify
t_code "dos subjects bien configurados -> conforme" 0
w="$(compliant_world two-missing)"
echo "assertion.sub in ['${SUBJECT}', '${S2}']" > "$w/provider_condition"
SUBJECTS_OVERRIDE="${SUBJECT};${S2}" run_script "$w" verify
t_code "falta el binding del segundo subject -> falla" 1

# ================================================================ plan / apply
section "plan: no cambia nada"
w="$(empty_world plan)"
printf '%s\n' "$BUILD" "$RUNTIME" > "$w/sa_exists"; touch "$w/ar"
run_script "$w" plan
t_code "termina con código 0" 0
t_has  "anuncia DRY_RUN" "DRY_RUN completado"
t_has  "crea el pool" "workload-identity-pools create ado-pool"
# 'plan' imprime cada comando escapado con printf %q: así se puede copiar y pegar sin riesgo
# (el subject lleva espacios y comillas dentro de la condición).
t_has  "crea el provider con la condición EXACTA por subject (escapada)" "--attribute-condition=assertion.sub\ in\ \[\'sc://acme/Mi\ Proyecto/gcp-conn\'\]"
t_has  "enlaza al principal exacto (principal://, no principalSet)" "principal://iam.googleapis.com/${POOLPATH}/subject/"
t_hasnt "nunca usa principalSet" "principalSet"
t_hasnt "nunca crea llaves" "keys create"
t_hasnt "nunca da roles amplios" "roles/owner"
t_no_mutations "no ejecuta ningún cambio" "$w"
w2="$(empty_world plan2)"; printf '%s\n' "$BUILD" "$RUNTIME" > "$w2/sa_exists"; touch "$w2/ar"
run_script "$w2" apply --dry-run
t_has "'apply --dry-run' equivale a 'plan'" "DRY_RUN completado"

section "apply"
w="$(empty_world apply-nosa)"
run_script "$w" apply
t_code "sin la SA del build/runtime -> aborta (código 2)" 2
t_has  "explica qué falta" "no existe en el proyecto"

w="$(compliant_world apply-idempotent)"
run_script "$w" apply
t_code "sobre una configuración conforme: idempotente y verifica" 0
t_has  "corre la verificación posterior" "VERIFICACIÓN POST-APPLY"
t_has  "no recrea el pool existente" "pool ya existe"
t_has  "imprime los valores para la service connection" "VALORES PARA LA SERVICE CONNECTION"
t_has  "indica el nombre de la conexión" "nombre de la conexión: gcp-conn"

w="$(compliant_world apply-create-missing)"
: > "$w/sa_exists"; echo "$FED" > "$w/sa_exists"
EXTRA_ENV="CREATE_MISSING_SA=true" run_script "$w" apply --dry-run
t_has  "con CREATE_MISSING_SA=true simula crear las SA faltantes" "service-accounts create cloudbuild-deployer"

# ================================================================ preflight
section "preflight"
w="$(compliant_world pre-ok)"
run_script "$w" preflight
t_code "configuración conforme -> 0" 0
w="$(empty_world pre-empty)"; rm "$w/account"
run_script "$w" preflight
t_nonzero "sin cuenta, SA ni registro -> falla"
t_has "pide autenticarse" "gcloud auth login"
t_no_mutations "es de solo lectura" "$w"

# ================================================================ entradas
section "validación de entradas"
w="$(compliant_world input)"
run_script "$w" verify
EXTRA_ENV="" ; SUBJECTS_OVERRIDE="sin-formato" run_script "$w" verify
t_code "subject sin formato sc://... -> código 2" 2
SUBJECTS_OVERRIDE="sc://acme/Proyecto/it's" run_script "$w" verify
t_code "subject con comilla simple (rompería la condición) -> código 2" 2
unset SUBJECTS_OVERRIDE
OUT="$(env WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="$PROJECT" ADO_ORG_ID="$ORG" ADO_SUBJECTS="" bash "$SCRIPT" verify 2>&1)"; CODE=$?
t_nonzero "ADO_SUBJECTS vacío -> falla"
OUT="$(env WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="$PROJECT" ADO_ORG_ID="$ORG" ADO_SUBJECTS=" ; ;" bash "$SCRIPT" verify 2>&1)"; CODE=$?
t_code "ADO_SUBJECTS con solo separadores -> código 2" 2
OUT="$(env WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="$PROJECT" ADO_ORG_ID="no-es-guid" ADO_SUBJECTS="$SUBJECT" bash "$SCRIPT" verify 2>&1)"; CODE=$?
t_code "ADO_ORG_ID que no es un GUID -> código 2" 2
OUT="$(env WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="Mal ID" ADO_ORG_ID="$ORG" ADO_SUBJECTS="$SUBJECT" bash "$SCRIPT" verify 2>&1)"; CODE=$?
t_code "PROJECT_ID inválido -> código 2" 2
OUT="$(env -u ADO_ORG_ID WORLD="$w" PATH="$HERE/bin:$PATH" PROJECT_ID="$PROJECT" ADO_SUBJECTS="$SUBJECT" bash "$SCRIPT" verify 2>&1)"; CODE=$?
t_nonzero "falta ADO_ORG_ID -> falla"
OUT="$(bash "$SCRIPT" borrar 2>&1)"; CODE=$?
t_code "subcomando desconocido -> código 2" 2

# ================================================================ resultado
echo
echo "Resultado: ${PASSED} ok, ${FAILED} fallidos"
[ "$FAILED" -eq 0 ]
