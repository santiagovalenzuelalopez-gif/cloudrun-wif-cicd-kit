# Migrar un pipeline de "espejo en GitHub + trigger" a WIF

Guía para pasar de un pipeline que copia el repo a un espejo y deja que un trigger de Cloud Build lo construya, a despliegue directo desde Azure DevOps con federación. Está pensada para hacerlo **servicio por servicio** y con marcha atrás en cualquier punto.

## Principios

1. **Un piloto, una rama.** Migrar primero la rama de QA de un servicio; las demás ramas siguen con el puente hasta que el piloto esté validado.
2. **Nada se borra al principio.** Lo viejo se *deshabilita*; se borra cuando pasa el tiempo suficiente sin incidencias.
3. **El `cloudbuild.yaml` del servicio es la fuente de verdad**: el trigger antiguo y el pipeline nuevo ejecutan el mismo archivo, de modo que el resultado del despliegue es el mismo.

## Pasos

### 1. Preparar GCP (una sola vez por proyecto)

```bash
./scripts/wif-setup.sh preflight && ./scripts/wif-setup.sh plan   # revisar
./scripts/wif-setup.sh apply                                       # termina con verify
```

El bucket de staging, las SAs y los permisos del registro ya suelen existir si había un trigger funcionando; `apply` solo añade lo que falta.

### 2. Preparar Azure DevOps (la persona con rol de administrador de la organización)

1. Instalar la extensión *Google Cloud Auth*.
2. Crear la service connection **Google Cloud (WIF)** con los valores que imprimió `apply` (el nombre debe coincidir con el subject).
3. Autorizar **solo** el pipeline que corresponde sobre la conexión.

### 3. Migrar el pipeline piloto (rama de QA)

- Añadir a la rama de QA los tres pasos de [`pipelines/azure-pipelines.yml`](../pipelines/azure-pipelines.yml) y dejar las demás ramas como están.
- Comprobar que el `cloudbuild.yaml` cumple el contrato: acepta `_SERVICE_NAME`, etiqueta con `${COMMIT_SHA}`.
- **Primera prueba contra un servicio desechable** (un nombre de servicio temporal), no contra el real: así los errores de plataforma no afectan a nada. Se borra después.
- Cuando funcione, apuntar al servicio real y desplegar.

### 4. Validar

- El build termina en `SUCCESS` y la revisión nueva recibe el 100 % del tráfico.
- `GET /health` responde y las variables de entorno y secretos siguen intactos (los define el `cloudbuild.yaml`).
- No hay errores en los logs del servicio.
- `wif-setup.sh verify` sigue en `FAIL=0`.

### 5. Limpiar (con calma)

| Qué | Cómo |
|---|---|
| Trigger antiguo de Cloud Build | **Deshabilitar** primero; exportar su definición como respaldo; borrar cuando haya confianza |
| Llave estática de la SA que se migra | **Deshabilitarla**; si en unos días nadie reporta fallos, borrarla (`keys delete`). `verify` falla mientras haya una activa |
| Variables del *variable group* que ya no se usan | Quitar solo las que ya no referencia ningún pipeline |
| Repo espejo en GitHub y su token | Archivar/borrar cuando todas las ramas estén migradas; revocar el token |

## Marcha atrás

El despliegue es una revisión de Cloud Run: volver atrás es mover el tráfico a la revisión anterior.

```bash
gcloud run services update-traffic <servicio> --region=<región> --project=<proyecto> \
  --to-revisions=<REVISION_ANTERIOR>=100
```

Anota la revisión previa **antes** del primer despliegue por la vía nueva. Si el problema es de federación (no del servicio), basta con volver a habilitar el trigger antiguo: no se borró.

## Cuándo NO migrar una rama

Una rama puede quedar fuera del alcance si el despliegue depende de algo que no es de CI/CD (por ejemplo, datos que el servicio nuevo necesita y que aún no existen en ese entorno). Migrar el pipeline no arregla eso: desplegar sin los datos tumbaría el servicio real. En ese caso se deja el puente como está y se trata como trabajo de datos, no de plataforma.

## Pendiente típico tras la migración

- Mover el pool a un proyecto de identidad dedicado antes de producción.
- Una conexión por cliente/entorno.
- Migrar el resto de servicios con el mismo patrón (para el mismo proyecto de ADO no hay que tocar GCP).
