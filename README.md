# Servicio de lista negra global de emails

Microservicio Flask para agregar y consultar emails en la lista negra global. Se despliega en AWS Elastic Beanstalk con RDS PostgreSQL.

## Correr en local

```bash
python -m venv .venv
source .venv/bin/activate    ||  .venv\Scripts\Activate.ps1
pip install -r requirements.txt
export DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5432/blacklist   || $env:DATABASE_URL="sqlite:///local.db"
export JWT_SECRET_KEY=un-secreto-largo
flask --app application create-token
python application.py
```

El comando `create-token` imprime el token estatico. Se envia en el header `Authorization: Bearer <token>`. Si cambia `JWT_SECRET_KEY` hay que generar el token otra vez.

Si ya se corrio una ves solo serian estos comandos
.venv\Scripts\Activate.ps1
$env:DATABASE_URL="sqlite:///local.db"
$env:JWT_SECRET_KEY="vamo a probar un sectreo random para configuracion de los 32 caracteres distribuidos"
python application.py

## Variables de entorno

| Variable | Uso |
|---|---|
| `JWT_SECRET_KEY` | Secreto con el que se firma el token. Debe ser igual en cada instancia. |
| `RDS_HOSTNAME`, `RDS_PORT`, `RDS_DB_NAME`, `RDS_USERNAME`, `RDS_PASSWORD` | Las inyecta Beanstalk cuando la RDS esta asociada al entorno. |
| `DATABASE_URL` | Alternativa para correr en local o si la RDS no esta asociada. |

## Endpoints

| Metodo | Ruta | Auth | Descripcion |
|---|---|---|---|
| GET | `/health` | No | Health check para Beanstalk |
| POST | `/blacklists` | Bearer | Agrega un email a la lista negra global |
| GET | `/blacklists/<string:email>` | Bearer | Consulta si un email está en la lista negra global |

### POST /blacklists

```json
{
  "email": "cliente@ejemplo.com",
  "app_uuid": "3f2b8c1e-5a4d-4e8b-9c1a-7d6e5f4a3b2c",
  "blocked_reason": "Solicito no recibir correos"
}
```

Respuestas: `201` creado, `400` datos invalidos, `401` sin token o token invalido, `409` el email ya estaba en la lista.

### GET /blacklists/<string:email>

Header: `Authorization: Bearer <token>`

Respuesta si está en la lista (`200 OK`):
```json
{
  "is_blocked": true,
  "blocked_reason": "Solicito no recibir correos"
}
```

Respuesta si no está en la lista (`200 OK`):
```json
{
  "is_blocked": false,
  "blocked_reason": null
}
```

## Colección Postman

En la carpeta `postman/` se encuentran la colección y el environment listos para importar:
* `blacklists_collection.json`: Casos de prueba para todos los endpoints (éxitos, 400, 401, 409).
* `blacklists_environment.json`: Variables `base_url` y `token`.

## Despliegue

Subir el contenido de la carpeta como zip a Beanstalk, con `application.py` en la raiz del zip. Configurar `/health` como ruta del health check.


token de momento: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmcmVzaCI6ZmFsc2UsImlhdCI6MTc5MTkxMjA2MSwianRpIjoiNjQyNjZiMTgtNDE5OS00YTVjLWIxZGEtZmU0ODU5NWE1YTZkIiwidHlwZSI6ImFjY2VzcyIsInN1YiI6ImJsYWNrbGlzdC1jbGllbnQiLCJuYmYiOjE3OTE5MTIwNjEsImNzcmYiOiI1OWFmNDkzNS00NDE1LTRlYjQtYmRlYy0xMjZmMjNlOGYxMTcifQ.G-dlhkUg2SvnF5XUCLl9z8N1eTODw7Mi8xnjbhWV87A
## Entrega 3 – Entrega continua en AWS Fargate

Arquitectura: GitHub (`main`) → CodePipeline → CodeBuild (`pytest` + `docker build` + push a ECR) → CodeDeploy (blue/green) → ECS Fargate detrás de un Application Load Balancer, con RDS PostgreSQL como base de datos.

| Archivo | Uso |
|---|---|
| `Dockerfile` | Imagen del microservicio (gunicorn en el puerto 5000) |
| `buildspec.yml` | Corre las pruebas, construye y publica la imagen en ECR y genera `imageDetail.json` |
| `taskdef.json` | Plantilla de la definición de tarea de Fargate (`<IMAGE1_NAME>` la reemplaza CodePipeline) |
| `appspec.yaml` | Especificación de CodeDeploy para ECS (contenedor `blacklist-app`, puerto 5000) |
| `infra/setup.sh` | Crea la infraestructura desde AWS CloudShell y hace el despliegue manual inicial |
| `infra/pipeline.sh` | Crea el pipeline `blacklist-pipeline` |
| `infra/token.py` | Genera el token Bearer con el secreto guardado en SSM |
| `infra/teardown.sh` | Elimina los recursos al terminar |

Los secretos (`DATABASE_URL` y `JWT_SECRET_KEY`) viven en AWS Systems Manager Parameter Store y la tarea los recibe como variables de entorno; no están en el repositorio.
