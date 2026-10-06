#!/usr/bin/env bash
# wif-setup.sh — Federación de identidades Azure DevOps -> Google Cloud (Workload Identity
# Federation) para desplegar a Cloud Run SIN llaves de service account, con mínimo privilegio.
#
# QUÉ CREA (idempotente: se puede repetir sin duplicar nada)
#   - Workload Identity Pool + provider OIDC, con una condición por lista EXACTA de subjects.
#   - Una service account FEDERADA que solo puede SOMETER builds (gcloud builds submit).
#   - Permisos mínimos para ella y para la SA que EJECUTA el build (staging, registro).
#   No crea llaves, no toca servicios, revisiones ni triggers existentes.
#
# USO
#   wif-setup.sh preflight         SOLO LECTURA: qué hay, qué falta y qué podría bloquear
#   wif-setup.sh plan              SIMULACIÓN: imprime los comandos de 'apply' sin ejecutarlos
#   wif-setup.sh apply             aplica y, al terminar, corre 'verify'
#   wif-setup.sh verify            SOLO LECTURA: comprueba el mínimo privilegio (debe dar FAIL=0)
#   (también: apply --dry-run, equivalente a plan)
#
# CONFIGURACIÓN (variables de entorno)
#   Obligatorias
#     PROJECT_ID     proyecto de GCP
#     ADO_ORG_ID     GUID de la organización de Azure DevOps
#     ADO_SUBJECTS   uno o varios subjects 'sc://<org>/<proyecto ADO>/<conexión>' separados por ';'
#                    (el nombre del proyecto va TAL CUAL, con espacios si los tiene)
#   Opcionales (con valor por defecto)
#     POOL=ado-pool  PROVIDER=ado-oidc-provider
#     FED_SA_NAME=ado-deployer          SA federada (solo somete builds)
#     BUILD_SA_NAME=cloudbuild-deployer SA que ejecuta el build y el deploy (debe existir)
#     RUNTIME_SA_NAME=cloudrun-runtime  SA de runtime de Cloud Run (debe existir)
#     STAGING_BUCKET=<PROJECT_ID>_cloudbuild   STAGING_LOCATION=US
#     REGISTRY_MODE=artifact-registry|gcr      AR_LOCATION=us-central1  AR_REPOSITORY=cloud-run-images
#     CREATE_MISSING_SA=false           true = crea las SA de build/runtime si faltan (sin roles)
#     ISSUER_URI  AUDIENCE              ver docs/ARQUITECTURA.md (el issuer de ADO puede cambiar)
#     PROJECT_NUMBER                    se detecta solo; útil si no se puede leer el proyecto
#
# PERMISOS de quien ejecuta 'apply': Owner, o Workload Identity Pool Admin + Service Account Admin
# + Project IAM Admin + Storage Admin + Service Usage Admin sobre el proyecto.
#
# Después de aplicar cambios de IAM, VERIFICAR siempre ('verify'): un add-iam-policy-binding
# mal escapado puede dejar un binding comodín inesperado.
set -Eeuo pipefail

# ---------------------------------------------------------------- utilidades
PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }
section() { echo; echo "== $* =="; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

usage() { sed -n '2,38p' "$0"; }

# ---------------------------------------------------------------- argumentos
PHASE="${1:-}"
case "$PHASE" in
  preflight|apply|verify) ;;
  plan) PHASE="apply"; set -- "$PHASE" --dry-run ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Uso: $0 <preflight|plan|apply|verify> [--dry-run]   (ver --help)" >&2; exit 2 ;;
esac
shift
DRY_RUN="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
    *) echo "Opción desconocida: $arg (solo --dry-run)" >&2; exit 2 ;;
  esac
done
if [ "$DRY_RUN" = "true" ] && [ "$PHASE" != "apply" ]; then
  echo "(--dry-run solo aplica a 'apply'; preflight y verify ya son de solo lectura)"
fi

run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '  [DRY-RUN] '; printf '%q ' "$@"; printf '\n'; return 0
  fi
  "$@"
}

# gcloud en Windows/Git Bash emite saltos CRLF; se normaliza para que las comparaciones de texto
# funcionen igual en Linux, Cloud Shell y Windows.
gcloud() { command gcloud "$@" | tr -d '\r'; }

# ---------------------------------------------------------------- configuración
: "${PROJECT_ID:?Falta PROJECT_ID (proyecto de GCP)}"
: "${ADO_ORG_ID:?Falta ADO_ORG_ID (GUID de la organización de Azure DevOps)}"
: "${ADO_SUBJECTS:?Falta ADO_SUBJECTS (sc://org/proyecto/conexion, varios separados por ';')}"

[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "PROJECT_ID inválido: '$PROJECT_ID'"
[[ "$ADO_ORG_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] || die "ADO_ORG_ID no es un GUID: '$ADO_ORG_ID'"

POOL="${POOL:-ado-pool}"
PROVIDER="${PROVIDER:-ado-oidc-provider}"
FED_SA_NAME="${FED_SA_NAME:-ado-deployer}"
BUILD_SA_NAME="${BUILD_SA_NAME:-cloudbuild-deployer}"
RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-cloudrun-runtime}"
STAGING_BUCKET="${STAGING_BUCKET:-${PROJECT_ID}_cloudbuild}"
STAGING_LOCATION="${STAGING_LOCATION:-US}"
REGISTRY_MODE="${REGISTRY_MODE:-artifact-registry}"
AR_LOCATION="${AR_LOCATION:-us-central1}"
AR_REPOSITORY="${AR_REPOSITORY:-cloud-run-images}"
CREATE_MISSING_SA="${CREATE_MISSING_SA:-false}"
ISSUER_URI="${ISSUER_URI:-https://vstoken.dev.azure.com/${ADO_ORG_ID}}"
AUDIENCE="${AUDIENCE:-api://AzureADTokenExchange}"
case "$REGISTRY_MODE" in artifact-registry|gcr) ;; *) die "REGISTRY_MODE inválido: '$REGISTRY_MODE'" ;; esac

FED_SA="${FED_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA="${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA="${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Subjects: lista con validación de formato. El proyecto de ADO puede llevar espacios.
IFS=';' read -r -a _RAW_SUBJECTS <<< "$ADO_SUBJECTS"
SUBJECTS=()
for s in "${_RAW_SUBJECTS[@]}"; do
  s="$(trim "$s")"
  [ -z "$s" ] && continue
  [[ "$s" =~ ^sc://[^/]+/[^/]+/[^/]+$ ]] || die "Subject con formato inválido: '$s' (esperado sc://<org>/<proyecto>/<conexión>)"
  case "$s" in *"'"*) die "El subject no puede contener comillas simples: '$s'" ;; esac
  SUBJECTS+=("$s")
done
[ "${#SUBJECTS[@]}" -ge 1 ] || die "ADO_SUBJECTS no contiene ningún subject"

# Condición del provider: lista EXACTA de subjects permitidos (nunca por prefijo).
COND_LIST=""
for s in "${SUBJECTS[@]}"; do COND_LIST="${COND_LIST:+$COND_LIST, }'${s}'"; done
CONDITION="assertion.sub in [${COND_LIST}]"

# Número del proyecto (hace falta para armar los principals).
PROJECT_NUMBER="${PROJECT_NUMBER:-}"
if [ -z "$PROJECT_NUMBER" ]; then
  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)"
fi
if [ -z "$PROJECT_NUMBER" ]; then
  if [ "$DRY_RUN" = "true" ]; then PROJECT_NUMBER="<PROJECT_NUMBER>"
  elif [ "$PHASE" != "preflight" ]; then die "No se pudo leer el proyecto $PROJECT_ID (¿permisos o ID incorrecto?)"; fi
fi

member_for() {
  printf 'principal://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s/subject/%s' \
    "$PROJECT_NUMBER" "$POOL" "$1"
}
PROVIDER_PATH="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"

sa_exists()      { gcloud iam service-accounts describe "$1" --project="$PROJECT_ID" --format='value(email)' >/dev/null 2>&1; }
bucket_exists()  { gcloud storage buckets describe "gs://$1" --format='value(name)' >/dev/null 2>&1; }
pool_exists()    { gcloud iam workload-identity-pools describe "$POOL" --location=global --project="$PROJECT_ID" >/dev/null 2>&1; }
provider_exists(){ gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global --workload-identity-pool="$POOL" --project="$PROJECT_ID" >/dev/null 2>&1; }
provider_field() { gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global --workload-identity-pool="$POOL" --project="$PROJECT_ID" --format="$1" 2>/dev/null || true; }
ar_exists()      { gcloud artifacts repositories describe "$AR_REPOSITORY" --location="$AR_LOCATION" --project="$PROJECT_ID" >/dev/null 2>&1; }
api_enabled()    { [ -n "$(gcloud services list --enabled --project="$PROJECT_ID" --filter="config.name=$1" --format='value(config.name)' 2>/dev/null)" ]; }

# "rol|miembro" de la política IAM de una SA / bucket / repo de imágenes.
sa_bindings() {
  gcloud iam service-accounts get-iam-policy "$1" --project="$PROJECT_ID" \
    --flatten='bindings[].members' --format='csv[no-heading,separator="|"](bindings.role,bindings.members)' 2>/dev/null || true
}
project_roles_of() {
  gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
    --filter="bindings.members:serviceAccount:$1" --format='value(bindings.role)' 2>/dev/null | sort | tr '\n' ' '
}

required_apis() {
  local apis=(sts.googleapis.com iamcredentials.googleapis.com iam.googleapis.com cloudbuild.googleapis.com run.googleapis.com storage.googleapis.com)
  [ "$REGISTRY_MODE" = artifact-registry ] && apis+=(artifactregistry.googleapis.com)
  printf '%s\n' "${apis[@]}"
}

banner() {
  echo "Proyecto ........ $PROJECT_ID (nº ${PROJECT_NUMBER:-?})"
  echo "Fase ............ $PHASE$([ "$DRY_RUN" = "true" ] && echo ' (DRY_RUN)')"
  echo "Pool/Provider ... $POOL / $PROVIDER"
  echo "Issuer .......... $ISSUER_URI"
  echo "SA federada ..... $FED_SA"
  echo "SA build ........ $BUILD_SA    SA runtime: $RUNTIME_SA"
  echo "Registro ........ $REGISTRY_MODE$([ "$REGISTRY_MODE" = artifact-registry ] && echo " ($AR_LOCATION/$AR_REPOSITORY)")"
  echo "Bucket staging .. gs://$STAGING_BUCKET"
  echo "Subjects ADO .... ${#SUBJECTS[@]}"
  for s in "${SUBJECTS[@]}"; do echo "                  - $s"; done
}

summary() {
  echo
  echo "Resumen: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# ================================================================ PREFLIGHT
phase_preflight() {
  section "Identidad de quien ejecuta"
  local acct; acct="$(gcloud config get-value account 2>/dev/null || true)"
  if [ -n "$acct" ]; then ok "gcloud autenticado como $acct"; else bad "gcloud sin cuenta activa (gcloud auth login)"; fi

  section "Proyecto"
  if [ -z "$PROJECT_NUMBER" ]; then
    bad "No se puede leer el proyecto $PROJECT_ID (ID incorrecto o sin permisos)"; return
  fi
  ok "Proyecto accesible (número $PROJECT_NUMBER)"
  if gcloud projects get-iam-policy "$PROJECT_ID" --format='value(etag)' >/dev/null 2>&1; then
    ok "Puede leer la política IAM del proyecto"
  else
    warn "No puede leer la política IAM del proyecto: 'apply' probablemente fallará por permisos"
  fi

  section "APIs necesarias"
  local a
  while IFS= read -r a; do
    if api_enabled "$a"; then ok "$a habilitada"; else warn "$a NO habilitada ('apply' la habilita)"; fi
  done < <(required_apis)

  section "Service accounts"
  local pair kind email
  for pair in "build:$BUILD_SA" "runtime:$RUNTIME_SA"; do
    kind="${pair%%:*}"; email="${pair#*:}"
    if sa_exists "$email"; then ok "SA $kind existe: $email"
    elif [ "$CREATE_MISSING_SA" = "true" ]; then warn "SA $kind NO existe ($email); 'apply' la creará (CREATE_MISSING_SA=true), sin roles de run/logs/registro"
    else bad "SA $kind NO existe: $email (debe existir; o usar CREATE_MISSING_SA=true)"; fi
  done
  if sa_exists "$FED_SA"; then
    ok "SA federada ya existe: $FED_SA"
    local ukeys; ukeys="$(gcloud iam service-accounts keys list --iam-account="$FED_SA" --managed-by=user --format='value(name.basename(),disabled)' 2>/dev/null || true)"
    if [ -n "$ukeys" ]; then warn "La SA federada tiene llaves de usuario (no debería): $(echo "$ukeys" | tr '\n' ' ')"; fi
  else
    info "SA federada no existe: 'apply' la creará"
  fi

  section "Permisos de la SA del build (informativo: deben existir; este script no los otorga)"
  if sa_exists "$BUILD_SA"; then
    local broles; broles="$(project_roles_of "$BUILD_SA")"
    info "Roles de proyecto de ${BUILD_SA_NAME}: ${broles:-<ninguno>}"
    if echo "$broles" | grep -Eq 'roles/run\.(developer|admin)'; then ok "${BUILD_SA_NAME} puede desplegar en Cloud Run (run.developer/admin)"
    else warn "${BUILD_SA_NAME} no tiene roles/run.developer ni run.admin: 'gcloud run deploy' fallaría"; fi
    if echo "$broles" | grep -q 'roles/logging.logWriter'; then ok "${BUILD_SA_NAME} puede escribir logs (logging.logWriter)"
    else warn "${BUILD_SA_NAME} sin logging.logWriter: con CLOUD_LOGGING_ONLY el build fallaría al registrar logs"; fi
    if echo "$broles" | grep -q 'roles/iam.serviceAccountUser' || \
       sa_bindings "$RUNTIME_SA" | grep -qF "roles/iam.serviceAccountUser|serviceAccount:${BUILD_SA}"; then
      ok "${BUILD_SA_NAME} puede actuar como la SA de runtime (${RUNTIME_SA_NAME})"
    else warn "${BUILD_SA_NAME} no puede actuar como ${RUNTIME_SA_NAME}: el deploy de servicios que la usan fallaría"; fi
  fi

  section "Bucket de staging y registro de imágenes"
  if bucket_exists "$STAGING_BUCKET"; then ok "Bucket gs://$STAGING_BUCKET existe"
  else warn "Bucket gs://$STAGING_BUCKET no existe: 'apply' lo creará en $STAGING_LOCATION"; fi
  if [ "$REGISTRY_MODE" = artifact-registry ]; then
    if ar_exists; then ok "Repo Artifact Registry $AR_LOCATION/$AR_REPOSITORY existe"
    else bad "Repo Artifact Registry $AR_LOCATION/$AR_REPOSITORY NO existe (este script no lo crea)"; fi
  else
    info "REGISTRY_MODE=gcr: verificar por su cuenta que ${BUILD_SA_NAME} pueda escribir en gcr.io/$PROJECT_ID"
  fi

  section "Federación existente"
  if pool_exists; then
    ok "Pool $POOL existe"
    if provider_exists; then info "Provider $PROVIDER ya existe: $(provider_field 'value(state,oidc.issuerUri)') ('apply' actualizará su condición)"
    else info "Provider $PROVIDER no existe: 'apply' lo creará"; fi
  else info "Pool $POOL no existe: 'apply' lo creará"; fi

  section "Triggers de Cloud Build existentes (informativo, NO se tocan)"
  local n; n="$(gcloud builds triggers list --project="$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  info "$n trigger(s) en el proyecto. Este script no los modifica."

  section "Políticas de organización que pueden afectar"
  local pol; pol="$(gcloud org-policies describe iam.workloadIdentityPoolProviders --effective --project="$PROJECT_ID" --format=yaml 2>/dev/null || true)"
  if [ -z "$pol" ]; then
    info "No se pudo leer iam.workloadIdentityPoolProviders (o no aplica). Si 'apply' falla al crear el provider, revisar esta política."
  elif echo "$pol" | grep -q "allowedValues" && ! echo "$pol" | grep -qF "$ISSUER_URI"; then
    bad "iam.workloadIdentityPoolProviders restringe issuers y NO incluye $ISSUER_URI"
  else
    ok "iam.workloadIdentityPoolProviders no bloquea el issuer $ISSUER_URI"
  fi
}

# ================================================================ APPLY
phase_apply() {
  if [ "$DRY_RUN" = "true" ]; then echo "*** DRY_RUN: no se ejecuta ningún cambio ***"; fi

  section "1/7: APIs"
  local apis=(); while IFS= read -r a; do apis+=("$a"); done < <(required_apis)
  run gcloud services enable "${apis[@]}" --project="$PROJECT_ID"

  section "2/7: Pool y provider (condición por subject exacto)"
  if ! pool_exists; then
    run gcloud iam workload-identity-pools create "$POOL" --location=global --project="$PROJECT_ID" --display-name="Azure DevOps"
  else echo "  pool ya existe"; fi
  if ! provider_exists; then
    run gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
      --location=global --project="$PROJECT_ID" --workload-identity-pool="$POOL" \
      --issuer-uri="$ISSUER_URI" --allowed-audiences="$AUDIENCE" \
      --attribute-mapping="google.subject=assertion.sub" \
      --attribute-condition="$CONDITION"
  else
    echo "  provider ya existe: se actualiza la condición"
    run gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
      --location=global --project="$PROJECT_ID" --workload-identity-pool="$POOL" \
      --attribute-condition="$CONDITION"
  fi

  section "3/7: Service accounts"
  if ! sa_exists "$FED_SA"; then
    run gcloud iam service-accounts create "$FED_SA_NAME" --project="$PROJECT_ID" \
      --display-name="Azure DevOps federated deployer (solo somete builds)"
  else echo "  $FED_SA ya existe"; fi
  local pair name email
  for pair in "$BUILD_SA_NAME:$BUILD_SA" "$RUNTIME_SA_NAME:$RUNTIME_SA"; do
    name="${pair%%:*}"; email="${pair#*:}"
    if sa_exists "$email"; then echo "  $email ya existe"
    elif [ "$CREATE_MISSING_SA" = "true" ]; then
      run gcloud iam service-accounts create "$name" --project="$PROJECT_ID"
      echo "  ATENCIÓN: $email creada SIN roles de run/logs/registro; asignarlos según su estándar."
    elif [ "$DRY_RUN" = "true" ]; then echo "  (simulación) $email no existe: el 'apply' real abortaría"
    else die "La SA $email no existe en el proyecto (usar CREATE_MISSING_SA=true para crearla)."; fi
  done

  section "4/7: Binding de federación (un principal por subject exacto)"
  local s
  for s in "${SUBJECTS[@]}"; do
    run gcloud iam service-accounts add-iam-policy-binding "$FED_SA" --project="$PROJECT_ID" \
      --role=roles/iam.workloadIdentityUser --member="$(member_for "$s")" --format='value(etag)'
  done

  section "5/7: Permisos mínimos de la SA federada (solo someter el build)"
  run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${FED_SA}" --role=roles/cloudbuild.builds.editor --condition=None --format='value(etag)'
  run gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA" --project="$PROJECT_ID" \
    --member="serviceAccount:${FED_SA}" --role=roles/iam.serviceAccountUser --format='value(etag)'

  section "6/7: Bucket de staging"
  if ! bucket_exists "$STAGING_BUCKET"; then
    run gcloud storage buckets create "gs://${STAGING_BUCKET}" --project="$PROJECT_ID" \
      --location="$STAGING_LOCATION" --uniform-bucket-level-access
  else echo "  gs://$STAGING_BUCKET ya existe"; fi
  # objectAdmin: subir/leer el tarball. legacyBucketReader: storage.buckets.get (gcloud verifica que
  # el bucket exista). NO se da storage.buckets.list: el pipeline pasa --gcs-source-staging-dir
  # explícito y gcloud omite ese listado.
  run gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${FED_SA}" --role=roles/storage.objectAdmin --format='value(etag)'
  run gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${FED_SA}" --role=roles/storage.legacyBucketReader --format='value(etag)'
  # Cloud Build lee el tarball COMO la SA del build (con un trigger conectado a un repo no hacía falta).
  run gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${BUILD_SA}" --role=roles/storage.objectViewer --format='value(etag)'

  section "7/7: Registro de imágenes para la SA del build"
  if [ "$REGISTRY_MODE" = artifact-registry ]; then
    if ar_exists || [ "$DRY_RUN" = "true" ]; then
      run gcloud artifacts repositories add-iam-policy-binding "$AR_REPOSITORY" \
        --location="$AR_LOCATION" --project="$PROJECT_ID" \
        --member="serviceAccount:${BUILD_SA}" --role=roles/artifactregistry.writer --format='value(etag)'
    else
      die "El repo Artifact Registry $AR_LOCATION/$AR_REPOSITORY no existe"
    fi
  else
    echo "  REGISTRY_MODE=gcr: sin cambios; verificar que ${BUILD_SA_NAME} ya pueda escribir en gcr.io/$PROJECT_ID"
  fi

  print_ado_values
}

print_ado_values() {
  cat <<EOF

================================================================================
VALORES PARA LA SERVICE CONNECTION "Google Cloud (WIF)" EN AZURE DEVOPS
(la crea un administrador de la organización de ADO; una conexión por proyecto ADO)
--------------------------------------------------------------------------------
  Workload Identity Pool Provider : ${PROVIDER_PATH}
  Service account                 : ${FED_SA}
EOF
  local s rest proj conn
  for s in "${SUBJECTS[@]}"; do
    rest="${s#sc://}"; rest="${rest#*/}"; proj="${rest%%/*}"; conn="${rest#*/}"
    echo "  Proyecto ADO: ${proj}  ->  nombre de la conexión: ${conn}   (subject: ${s})"
  done
  cat <<'EOF'
  IMPORTANTE: el nombre de la conexión y el del proyecto de ADO deben coincidir EXACTAMENTE
  con el subject (mayúsculas, espacios y ortografía), o GCP rechazará el canje de tokens.
================================================================================
EOF
}

# ================================================================ VERIFY
phase_verify() {
  section "Provider WIF"
  if ! provider_exists; then bad "Provider $PROVIDER no existe"
  else
    local st iss aud map cond
    st="$(provider_field 'value(state)')"
    iss="$(provider_field 'value(oidc.issuerUri)')"
    aud="$(provider_field 'value(oidc.allowedAudiences)')"
    # 'google.subject' lleva un punto: gcloud no puede formatearlo con value(...), se lee el mapa completo.
    map="$(provider_field 'value(attributeMapping)')"
    cond="$(provider_field 'value(attributeCondition)')"
    if [ "$st" = "ACTIVE" ]; then ok "Provider ACTIVE"; else bad "Provider en estado '$st'"; fi
    if [ "$iss" = "$ISSUER_URI" ]; then ok "Issuer correcto ($iss)"; else bad "Issuer inesperado: '$iss' (esperado $ISSUER_URI)"; fi
    if [ "$aud" = "$AUDIENCE" ]; then ok "Audience correcta"; else bad "Audiences inesperadas: '$aud'"; fi
    if [[ "$map" == *"google.subject"*"assertion.sub"* ]]; then ok "google.subject = assertion.sub"
    else bad "Mapping inesperado: '$map' (esperado google.subject=assertion.sub)"; fi
    # Condición exacta: 'in [...]' o, con un solo subject, la forma equivalente '== ...'.
    local single="assertion.sub == '${SUBJECTS[0]}'"
    if [ "$cond" = "$CONDITION" ] || { [ "${#SUBJECTS[@]}" -eq 1 ] && [ "$cond" = "$single" ]; }; then
      ok "Condición del provider = lista exacta de subjects"
    else
      bad "Condición inesperada: $cond"
    fi
  fi

  section "IAM de la SA federada (sin wildcards ni roles de más)"
  if ! sa_exists "$FED_SA"; then bad "SA federada $FED_SA no existe"
  else
    local expected=() actual=() role member s
    for s in "${SUBJECTS[@]}"; do expected+=("$(member_for "$s")"); done
    while IFS='|' read -r role member; do
      [ -z "$role" ] && continue
      if [ "$role" = "roles/iam.workloadIdentityUser" ]; then actual+=("$member")
      else bad "Rol inesperado en la SA federada: $role -> $member"; fi
    done < <(sa_bindings "$FED_SA")
    local e_sorted a_sorted
    e_sorted="$(printf '%s\n' "${expected[@]}" | sort)"
    a_sorted="$( [ "${#actual[@]}" -gt 0 ] && printf '%s\n' "${actual[@]}" | sort || true)"
    if [ "$e_sorted" = "$a_sorted" ]; then ok "workloadIdentityUser solo para los subjects esperados (principal:// exacto)"
    else bad "workloadIdentityUser difiere de lo esperado. Esperado:"$'\n'"$e_sorted"$'\n'"Actual:"$'\n'"$a_sorted"; fi
    if printf '%s\n' "${actual[@]:-}" | grep -q 'principalSet://'; then bad "Hay un principalSet en la SA federada (prohibido)"; fi

    section "Roles de proyecto de la SA federada"
    local roles; roles="$(project_roles_of "$FED_SA")"
    if [ "$roles" = "roles/cloudbuild.builds.editor " ]; then ok "Solo roles/cloudbuild.builds.editor"
    else bad "Roles de proyecto inesperados: ${roles:-<ninguno>} (esperado solo roles/cloudbuild.builds.editor)"; fi

    section "Llaves de usuario de la SA federada"
    local k line; k="$(gcloud iam service-accounts keys list --iam-account="$FED_SA" --managed-by=user --format='value(name.basename(),disabled)' 2>/dev/null || true)"
    if [ -z "$k" ]; then ok "Sin llaves de usuario"
    else
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | grep -qi 'true'; then warn "Llave de usuario DESHABILITADA: $line (borrarla cuando se confirme que no se usa)"
        else bad "Llave de usuario ACTIVA en la SA federada: $line (debe borrarse: la federación no usa llaves)"; fi
      done <<< "$k"
    fi
  fi

  section "SA del build: actAs, staging y registro"
  if sa_exists "$BUILD_SA"; then
    if sa_bindings "$BUILD_SA" | grep -qF "roles/iam.serviceAccountUser|serviceAccount:${FED_SA}"; then
      ok "${FED_SA_NAME} puede actuar como ${BUILD_SA_NAME} (solo sobre esa SA)"
    else bad "${FED_SA_NAME} NO tiene serviceAccountUser sobre ${BUILD_SA_NAME}"; fi
  else bad "SA del build $BUILD_SA no existe"; fi

  # Ninguna SA del proyecto (federada, build, runtime) debe tener un principalSet de este pool.
  local sa
  for sa in "$FED_SA" "$BUILD_SA" "$RUNTIME_SA"; do
    sa_exists "$sa" || continue
    if sa_bindings "$sa" | grep -q "principalSet://.*workloadIdentityPools/${POOL}/"; then
      bad "$sa tiene un binding principalSet sobre el pool $POOL (prohibido)"
    fi
  done

  if bucket_exists "$STAGING_BUCKET"; then
    local bp want
    bp="$(gcloud storage buckets get-iam-policy "gs://${STAGING_BUCKET}" --flatten='bindings[].members' \
      --format='csv[no-heading,separator="|"](bindings.role,bindings.members)' 2>/dev/null || true)"
    for want in "roles/storage.objectAdmin|serviceAccount:${FED_SA}" \
                "roles/storage.legacyBucketReader|serviceAccount:${FED_SA}" \
                "roles/storage.objectViewer|serviceAccount:${BUILD_SA}"; do
      if echo "$bp" | grep -qF "$want"; then ok "Bucket: $want"; else bad "Falta en gs://$STAGING_BUCKET: $want"; fi
    done
    if echo "$bp" | grep -Eq '\|(allUsers|allAuthenticatedUsers)$'; then bad "El bucket de staging es público (allUsers/allAuthenticatedUsers)"; fi
  else bad "Bucket gs://$STAGING_BUCKET no existe"; fi

  if [ "$REGISTRY_MODE" = artifact-registry ]; then
    if ar_exists; then
      local ap; ap="$(gcloud artifacts repositories get-iam-policy "$AR_REPOSITORY" --location="$AR_LOCATION" --project="$PROJECT_ID" \
        --flatten='bindings[].members' --format='csv[no-heading,separator="|"](bindings.role,bindings.members)' 2>/dev/null || true)"
      if echo "$ap" | grep -qF "roles/artifactregistry.writer|serviceAccount:${BUILD_SA}"; then
        ok "artifactregistry.writer de ${BUILD_SA_NAME} sobre $AR_REPOSITORY"
      else bad "Falta artifactregistry.writer de ${BUILD_SA_NAME} sobre $AR_REPOSITORY"; fi
      if echo "$ap" | grep -qF "serviceAccount:${FED_SA}"; then
        bad "La SA federada tiene permisos sobre el repo de imágenes (no debe: el push lo hace ${BUILD_SA_NAME})"
      else ok "La SA federada no tiene acceso al repo de imágenes"; fi
    else bad "Repo Artifact Registry $AR_LOCATION/$AR_REPOSITORY no existe"; fi
  fi
}

# ================================================================ main
banner
case "$PHASE" in
  preflight) phase_preflight; summary ;;
  verify)    phase_verify;    summary ;;
  apply)
    phase_apply
    if [ "$DRY_RUN" = "true" ]; then
      echo; echo "DRY_RUN completado: no se cambió nada."
    else
      section "VERIFICACIÓN POST-APPLY"
      phase_verify
      summary || { echo "La verificación post-apply falló: revisar antes de continuar."; exit 1; }
    fi ;;
esac
