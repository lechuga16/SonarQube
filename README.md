# SonarQube Docker Toolkit

Este repositorio empaqueta una instancia de SonarQube Community Edition, una base de datos Postgres y un contenedor efímero con Sonar Scanner más un script que recorre una lista blanca de proyectos locales. El objetivo es analizar varios repositorios sin instalar el scanner en el host.

## Componentes

- `docker-compose.yml` – servicios de SonarQube y Postgres.
- `Dockerfile.scanner` – imagen del scanner con `jq` preinstalado para acelerar ejecuciones.
- `run-scanner.ps1` / `run-scanner.sh` – generan un compose temporal y montan los repos en sus rutas reales.
- `process-projects.sh` – espera a que SonarQube esté disponible y ejecuta `sonar-scanner` por cada entrada en `whitelist.json`.
- `whitelist.json` – lista los repositorios del host que se van a analizar.
- `whitelist.schema.json` – esquema de validacion para `whitelist.json`.
- `.env` – almacena secretos y variables usadas por los scripts (git lo ignora). Revisa `.env.example` para ver la plantilla comentada.

## Prerrequisitos

- Docker Desktop (o motor Docker compatible) con soporte para Compose v2.
- Windows con WSL2 (configuración asumida), aunque cualquier SO capaz de ejecutar los contenedores es válido.
- Compartir en Docker Desktop (`Settings > Resources > File Sharing`) las carpetas del host que quieras analizar.

## Configuración inicial

1. **Copiar plantillas**
   - Duplica `.env.example` a `.env` y completa tus valores.
   - Revisa `docker-compose.yml` si necesitas ajustar puertos o credenciales.

2. **Variables de entorno (`.env`)**
   - `SONAR_TOKEN` – genera un User Token en `http://localhost:9000/account/security` tras el primer arranque de SonarQube.
   - `SONAR_HOST_URL` – URL usada por scripts en el host (por defecto `http://localhost:9000`).
   - `SCAN_PARALLELISM` – cantidad de proyectos a analizar en paralelo (1 = secuencial).
   - `SONAR_WAIT_TIMEOUT_SECONDS` y `SONAR_WAIT_INTERVAL_SECONDS` – controlan la espera al iniciar SonarQube.
   - Modifica las credenciales/JDBC solo si necesitas valores distintos a los predeterminados.

3. **Proyectos (`whitelist.json`)**
   ```json
   {
     "projects": [
       { "hostPath": "C:\\Repos\\ProjectA" }
     ]
   }
   ```
   - Los mounts se generan automáticamente desde `projects` cuando usas `run-scanner.ps1` o `run-scanner.sh`.
   - Si necesitas entrar a una subcarpeta específica, agrega la propiedad opcional `path` relativa al `hostPath`.
   - Si quieres etiquetar los registros del script con un nombre distinto al de la carpeta, puedes añadir el campo opcional `projectKey`; el valor efectivo se toma del `sonar-project.properties` del repositorio.

4. **`sonar-project.properties` en cada repositorio**
   - Define ahí `sonar.projectKey`, `sonar.sources`, exclusiones, reportes de cobertura, etc., para que el repo sea auto-contenido.

## Puesta en marcha

1. Inicia SonarQube y Postgres:
   ```bash
   docker compose up -d sonarqube
   ```
2. Espera a que la interfaz esté disponible en `http://localhost:9000`, inicia sesión (credenciales iniciales admin/admin) y genera tu `SONAR_TOKEN`.
3. Lanza el scanner bajo demanda:
   ```powershell
   ./run-scanner.ps1
   ```
   El script hará lo siguiente:
   - Consultar el estado de SonarQube hasta que responda `UP`.
   - Resolver cada `hostPath` contra los montajes generados.
   - Entrar al directorio del repositorio y ejecutar `sonar-scanner`.
   - Usar caches en `/work/.sonar` y directorios de trabajo en `/work/.scannerwork`.

### Scanner dinámico (monta proyectos en cualquier ruta)

Si tienes proyectos en rutas distintas del disco, usa el generador:

1. Define tus proyectos en `whitelist.json` (solo `projects` es suficiente).
2. Ejecuta:
   ```powershell
   ./run-scanner.ps1
   ```
   El script genera un `docker-compose.generated.yml` y un `whitelist.generated.json` en base a los `hostPath`,
   monta cada proyecto donde esté y ejecuta el scanner. Por defecto borra los archivos generados al final
   (usa `-KeepGenerated` si quieres conservarlos).

   En bash (Linux/macOS):
   ```bash
   ./run-scanner.sh
   ```
   Puedes mantener los archivos generados con `KEEP_GENERATED=1 ./run-scanner.sh`.

- Los datos, extensiones y logs de SonarQube persisten en los volúmenes Docker (`sonarqube_data`, `sonarqube_extensions`, `sonarqube_logs`).
- Regenera `SONAR_TOKEN` cuando revoques el existente y actualiza `.env` de inmediato.

## Resolución de problemas

- **401 Authentication errors** – el scanner no pudo autenticarse con el token. Genera uno nuevo y actualiza `.env`.
- **"No se encuentra sonar-project.properties"** – el repositorio montado no tiene el archivo. Agrégalo (el volumen está montado en modo solo lectura).
- **Advertencias de mapeo de montajes** – asegúrate de que el `hostPath` esté cubierto por algún prefijo `host` y que la carpeta esté compartida en Docker Desktop.

## Limpieza

Detén los contenedores conservando los volúmenes:
```bash
docker compose down
```
Elimina también los volúmenes si quieres un estado limpio:
```bash
docker compose down -v
```
