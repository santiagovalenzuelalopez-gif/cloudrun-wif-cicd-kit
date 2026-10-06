# Modelo de amenazas

Qué puede salir mal, qué alcance tendría y qué lo limita.

| Amenaza | Alcance si ocurre | Mitigaciones |
|---|---|---|
| **Se modifica un pipeline o una rama** y se ejecuta con la identidad federada | Someter un build **como la SA del build**: desplegar cualquier imagen en Cloud Run del proyecto | La SA federada no tiene `run`, registro ni IAM; la SA del build tiene solo los roles de despliegue. En producción: *Branch control* (solo `refs/heads/main`) y *Approvals* en el Environment. Conexiones separadas por entorno |
| **Otro pipeline de la organización usa la conexión** | Igual que la anterior | Desmarcar *Grant access to all pipelines* y autorizar **solo** los pipelines que corresponden. Una conexión por entorno (QA y producción nunca comparten) |
| **Robo de credenciales** | — | No hay llaves ni secretos de GCP en ADO. Los tokens duran minutos y están ligados a un subject exacto. `verify` falla si la SA federada tiene una llave de usuario activa |
| **Un binding demasiado amplio** (comodín, prefijo, pool completo) | Cualquier token del issuer podría impersonar a la SA | Doble control: condición del provider *y* binding por `principal://` exacto. `verify` rechaza cualquier `principalSet` |
| **Un administrador de ADO crea otra conexión** | Un subject nuevo no está en la condición: GCP lo rechaza | Cada conexión nueva exige un cambio explícito en GCP (`apply` con el subject nuevo) |
| **Renombrar el proyecto o la conexión en ADO** | El subject cambia y el canje falla (cierra, no abre) | El nombre debe coincidir exactamente; `apply` imprime los valores a usar |
| **La SA del build se usa para algo más** | Es la más poderosa de las tres | Sin `serviceAccountUser` a nivel de proyecto: solo la federada puede actuar como ella, y solo sobre esa SA. Roles de proyecto mínimos (`run.developer`, no `run.admin`) |
| **El bucket de staging expone el código fuente** | Lectura del código de los servicios | `verify` falla si el bucket es público; acceso solo para las dos SAs; *uniform bucket-level access* |
| **Secretos en variables de entorno de Cloud Run** | Visibles para cualquiera con acceso de lectura al servicio | `cloudbuild.yaml` de referencia: secretos con `--set-secrets` (Secret Manager); una comprobación del repo falla si el `--set-env-vars` contiene nombres tipo `PASSWORD`/`TOKEN`/`API_KEY` |
| **Servicios expuestos** | Cualquiera podría invocar el servicio | `--no-allow-unauthenticated` por defecto; cuenta de runtime dedicada (no la *default* de Compute) |
| **Un PR dispara un despliegue** | Código de una rama ajena ejecutándose con la identidad federada | `pr: none` en las plantillas (comprobado en los tests) |

## Qué confía en qué

- GCP confía en **Azure DevOps como emisor** de los tokens y en que los nombres de organización, proyecto y conexión del `sub` no se falsifiquen: quien administra la organización de ADO es parte de la base de confianza.
- El kit no protege contra un administrador de ADO malicioso con acceso a la conexión y a una rama permitida; lo que hace es **acotar lo que esa persona alcanza** (someter builds de la SA del build) y dejar rastro (logs de Cloud Build por SA).

## Recomendaciones adicionales

- **Producción**: mover el pool/provider a un **proyecto de identidad dedicado**, de modo que ni un compromiso de un proyecto de aplicación ni uno de los pipelines pueda modificar la federación.
- **Varios clientes o entornos**: una conexión por cliente/entorno y binding por subject exacto; nunca por prefijo, proyecto ni pool.
- **Llaves heredadas**: primero *deshabilitar* la llave estática de la SA que se migra y esperar unos días; si nadie reporta fallos, borrarla. `verify` avisa de las deshabilitadas y falla ante las activas.
- **Deriva**: ejecutar `wif-setup.sh verify` de forma periódica (tarea programada) y alertar ante un `FAIL`.
