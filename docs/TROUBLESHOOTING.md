# Troubleshooting y lecciones aprendidas

Cada fila es un error real encontrado al montar esta integración, con su causa verdadera (que casi nunca era la que sugería el mensaje) y qué enseñó.

## Errores

| Síntoma | Causa real | Lección |
|---|---|---|
| `No se obtuvo token OIDC` / *no explicit reference to service connection* | ADO exige que el job referencie la conexión desde una **tarea** que la declare como input; un `curl` al endpoint `oidctoken` desde un script no basta | Usar `GcpWifAuth@0` |
| `AzureCLI@2 … could not be found` | `AzureCLI@2` filtra las conexiones en estado **DRAFT** | Evitar la vía ARM para esto |
| `AADSTS700038` al hacer *Verify and save* | Las conexiones ARM llaman a Entra de verdad: el App ID no puede ser un valor de relleno | La vía ARM exige un App Registration real en el tenant; se descartó |
| `sub` de ~138 caracteres > límite de 127 bytes de `google.subject` | Subject opaco `/eid1/…` del issuer de Entra | El issuer de la extensión da un `sub` corto (`sc://org/proyecto/conexión`). Si algún día pasa a Entra: `assertion.sub.extract(...)` |
| `Failed to generate GCP access token` (log genérico, valores enmascarados) | El provider tenía el issuer de Entra y una condición atada al subject de una conexión ARM anterior | La extensión **no** usa Entra: usa el endpoint genérico de ADO. Se confirmó leyendo el código de la extensión (el VSIX es público) |
| `forbidden accessing the bucket … serviceusage.services.use` | Mensaje **engañoso**. Lo real: `gcloud builds submit` hace `GET` del bucket (`storage.buckets.get`) y luego **lista los buckets del proyecto** (`storage.buckets.list`) | Reproducir impersonando a la SA con `--verbosity=debug` para ver el 403 real. `--gcs-source-staging-dir` evita el listado; `legacyBucketReader` aporta `buckets.get` |
| `<SA del build> does not have storage.objects.get` | Cloud Build lee el tarball **como la SA del build**, no como la federada | `storage.objectViewer` sobre el bucket de staging para la SA del build |
| La imagen se publica con el tag vacío (`repo/servicio:`) | `${COMMIT_SHA}` solo lo rellenan los triggers | Pasar `COMMIT_SHA=$(Build.SourceVersion)` en `--substitutions` |
| Apareció un binding `principalSet://…/<pool>/*` que nadie pidió | No aclarado; sospecha: el escape de un miembro con espacios en PowerShell dentro de `add-iam-policy-binding` | **Verificar el IAM después de cada cambio.** Por eso existe `verify` |
| El canje de token falla con un nombre "idéntico" | El subject distingue mayúsculas, espacios y ortografía del **proyecto** y de la **conexión** | Copiar los nombres exactos; el script los valida y los entrecomilla |
| Un administrador de ADO no puede instalar la extensión / la mesa de ayuda cierra la solicitud | Instalar extensiones de Marketplace excede el alcance del soporte de primer nivel | Pedirlo a un **administrador de la organización de ADO**, con nombre propio y la aprobación del responsable adjunta |

## Suposiciones que resultaron falsas

- ❌ *"El issuer `vstoken` está muerto para todo."* Para las conexiones ARM sí (migraron a Entra), pero la **conexión creada por la extensión** sigue emitiendo tokens con `vstoken`.
- ❌ *"Se puede inspeccionar el token OIDC desde la extensión."* No lo expone (queda enmascarado). Se dedujo del código fuente y se confirmó probando.
- ❌ *"`objectAdmin` sobre el bucket basta."* Falta `buckets.get`: hace falta además `legacyBucketReader`.
- ❌ *"La SA federada también puede hacer el deploy."* Funcionaría, pero obligaría a darle `run.admin` y escritura en el registro: el despliegue se mueve a Cloud Build, como la SA del build (ver [ADR-2](ARQUITECTURA.md#adr-2-separación-de-funciones-entre-tres-service-accounts)).

## Cómo diagnosticar un canje de token fallido

1. `wif-setup.sh verify`: ¿issuer, audiencia y condición son los esperados?
2. Comparar el **subject exacto** (`sc://org/proyecto/conexión`) con el de la condición del provider, carácter por carácter.
3. Mirar en *Logs Explorer* los eventos de STS (`sts.googleapis.com`) y de impersonación (`iamcredentials.googleapis.com`).
4. Si el error es un 403 con un mensaje que menciona un permiso raro, **reproducirlo impersonando a la SA** con `gcloud ... --impersonate-service-account=<SA> --verbosity=debug`: el mensaje de la herramienta suele esconder la llamada que realmente falló.
5. Comprobar que el pipeline está autorizado sobre la conexión (ADO lo pide la primera vez).

## Lo que NO funciona (para no repetirlo)

- Obtener el token OIDC con `curl` desde un script de `bash`.
- Una conexión ARM manual con el issuer de Entra sin un App Registration real.
- `continueOnError: true` en la tarea de autenticación (deja correr los pasos siguientes sin credenciales).
- Desplegar con `gcloud run deploy` desde la identidad federada con permisos mínimos: fallará por diseño.
- Un binding por prefijo, por proyecto o por pool completo.
