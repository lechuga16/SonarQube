# SonarQube Docker Toolkit

Este repositorio empaqueta una instancia de SonarQube Community Edition, una base de datos Postgres y un contenedor efímero con Sonar Scanner más un script que recorre una lista blanca de proyectos locales. El objetivo es analizar varios repositorios sin instalar el scanner en el host.

## Componentes

- `docker-compose.example.yml` – archivo de referencia con los servicios de SonarQube, Postgres y el contenedor del scanner. Cópialo a `docker-compose.yml` y ajusta las rutas de los volúmenes del scanner.
- `Dockerfile.scanner` – extiende `sonarsource/sonar-scanner-cli` para incluir `jq`, la whitelist y el script `process-projects.sh` como entrypoint.
- `process-projects.sh` – espera a que SonarQube esté disponible y ejecuta `sonar-scanner` por cada entrada en `whitelist.json`.
- `whitelist.json` – lista los repositorios del host que se van a analizar y los pares host/contenedor que permiten resolver rutas dentro del contenedor.
- `.env` – almacena secretos y variables de montaje usadas por Docker Compose (git lo ignora). Revisa `.env.example` para ver la plantilla comentada.

## Prerrequisitos

- Docker Desktop (o motor Docker compatible) con soporte para Compose v2.
- Windows con WSL2 (configuración asumida), aunque cualquier SO capaz de ejecutar los contenedores es válido.
- Compartir en Docker Desktop (`Settings > Resources > File Sharing`) las carpetas del host que quieras analizar.

## Configuración inicial

1. **Copiar plantillas**
   - Duplica `.env.example` a `.env` y completa tus valores.
   - Duplica `docker-compose.example.yml` a `docker-compose.yml` y apunta los volúmenes del scanner a tus carpetas compartidas.

2. **Variables de entorno (`.env`)**
   - `SONAR_TOKEN` – genera un User Token en `http://localhost:9000/account/security` tras el primer arranque de SonarQube.
   - Modifica las credenciales/JDBC solo si necesitas valores distintos a los predeterminados.

3. **Montajes y proyectos (`whitelist.json`)**
   ```json
   {
     "mounts": [
       { "host": "C:/Repos", "container": "/work/src1" },
       { "host": "D:/Clientes", "container": "/work/src2" }
     ],
     "projects": [
         { "hostPath": "C:\\Repos\\ProjectA" }
     ]
   }
   ```
   - Cada `hostPath` debe quedar dentro de alguno de los prefijos `host` declarados.
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
   ```bash
   docker compose run --rm scanner
   ```
   El script hará lo siguiente:
   - Consultar el estado de SonarQube hasta que responda `UP`.
   - Resolver cada `hostPath` contra los montajes declarados.
   - Entrar al directorio del repositorio y ejecutar `sonar-scanner`.

- Los datos, extensiones y logs de SonarQube persisten en los volúmenes Docker (`sonarqube_data`, `sonarqube_extensions`, `sonarqube_logs`).
- Regenera `SONAR_TOKEN` cuando revoques el existente y actualiza `.env` de inmediato.

### Escaneo rápido de un solo proyecto

1. Duplica `whitelist.single.example.json` a `whitelist.single.json` y reemplaza las rutas por las de tu proyecto. Asegúrate de que el campo `container` coincida con `/work/project` (es donde se monta el repositorio en esta variante).
2. Define `SINGLE_PROJECT_HOST_PATH` con la ruta absoluta del proyecto. Puedes añadirlo a `.env` o pasarlo inline al comando (`SINGLE_PROJECT_HOST_PATH="C:/Repos/MiProyecto" docker compose ...`). Asegúrate también de que `SONAR_TOKEN` esté presente en `.env` o exportado en tu shell.
3. Ejecuta el scanner puntual (la primera vez descargará `jq` dentro del contenedor):
   ```bash
   docker compose -f docker-compose.scanner.yml run --rm scanner-single
   ```
   El servicio monta el proyecto en `/work/project`, reemplaza `whitelist.json` por tu `whitelist.single.json` y reutiliza `process-projects.sh` (montado desde el host) para analizar solo ese repositorio.
4. Si quieres usar otro archivo de whitelist, establece `SINGLE_WHITELIST_FILE` apuntando al JSON deseado antes de ejecutar el comando.

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
