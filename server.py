#!/usr/bin/env python3
"""Servidor local/persistente para FarmaSalud (solo biblioteca estándar de Python).
Sirve la web, escribe imágenes dentro de assets/ y mantiene el catálogo en data/catalogo.json.
Para publicar en Internet se requiere hosting con almacenamiento persistente y contraseña propia.
"""
from __future__ import annotations
import base64, binascii, hashlib, hmac, json, mimetypes, os, re, secrets, time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, unquote, parse_qs
from threading import RLock

ROOT = Path(__file__).resolve().parent
# Locally this defaults to the project folder, exactly as requested. A cloud host can
# point it at a persistent volume (for example /var/data) so uploads survive redeploys.
STORAGE_ROOT = Path(os.environ.get("FARMASALUD_STORAGE_DIR", str(ROOT))).resolve()
DATA_DIR = STORAGE_ROOT / "data"
ASSETS_DIR = STORAGE_ROOT / "assets"
STATE_FILE = DATA_DIR / "catalogo.json"
PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("FARMASALUD_HOST", "0.0.0.0")
ENV_ADMIN_PASSWORD = os.environ.get("FARMASALUD_ADMIN_PASSWORD")
ADMIN_PASSWORD = ""
GENERATED_ADMIN_PASSWORD = None
SESSION_COOKIE = "farmasalud_admin_session"
MAX_JSON_BYTES = 15 * 1024 * 1024
MAX_IMAGE_BYTES = 10 * 1024 * 1024
LOCK = RLock()
SESSIONS: dict[str, float] = {}

FOLDERS = {
    "product": "productos",
    "products": "productos",
    "producto": "productos",
    "promotion": "promociones",
    "promotions": "promociones",
    "promocion": "promociones",
    "founder": "fundadores",
    "founders": "fundadores",
    "fundador": "fundadores",
    "logo": "img",
    "icon": "iconos",
}
ALLOWED_MIMES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
}

for folder in [DATA_DIR, ASSETS_DIR / "img", ASSETS_DIR / "productos", ASSETS_DIR / "promociones", ASSETS_DIR / "fundadores", ASSETS_DIR / "iconos"]:
    folder.mkdir(parents=True, exist_ok=True)

# The demo password is generated once and stored outside the public static paths.
# For a public deployment, always define FARMASALUD_ADMIN_PASSWORD in the host settings.
ADMIN_SECRET_FILE = DATA_DIR / ".admin_secret"
if ENV_ADMIN_PASSWORD:
    ADMIN_PASSWORD = ENV_ADMIN_PASSWORD
elif ADMIN_SECRET_FILE.is_file():
    ADMIN_PASSWORD = ADMIN_SECRET_FILE.read_text(encoding="utf-8").strip()
if not ADMIN_PASSWORD:
    GENERATED_ADMIN_PASSWORD = secrets.token_urlsafe(12)
    ADMIN_PASSWORD = GENERATED_ADMIN_PASSWORD
    ADMIN_SECRET_FILE.write_text(ADMIN_PASSWORD, encoding="utf-8")
    try:
        ADMIN_SECRET_FILE.chmod(0o600)
    except OSError:
        pass


def default_state():
    return {"initialized": False, "products": [], "promotions": [], "founders": []}


def read_state():
    with LOCK:
        try:
            raw = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                return default_state()
            state = default_state()
            state["initialized"] = bool(raw.get("initialized", False))
            for key in ("products", "promotions", "founders"):
                state[key] = raw.get(key) if isinstance(raw.get(key), list) else []
            return state
        except (OSError, json.JSONDecodeError):
            return default_state()


def write_state(state):
    with LOCK:
        temp = STATE_FILE.with_suffix(".json.tmp")
        temp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(STATE_FILE)


def safe_image_reference(value):
    """Never persist data URLs/Base64. References must point to a file or HTTPS image."""
    if value is None or value == "":
        return ""
    if not isinstance(value, str):
        raise ValueError("La referencia de imagen debe ser texto.")
    value = value.strip()
    if value.startswith("data:image/"):
        raise ValueError("La imagen todavía es temporal. Súbela primero a assets/.")
    if value.startswith("https://"):
        return value
    if value.startswith("http://"):
        # Only HTTPS is accepted for remote images to avoid mixed-content warnings.
        raise ValueError("Las imágenes externas deben usar HTTPS.")
    value = value.lstrip("/")
    if not (value.startswith("assets/") or value.startswith("img/")):
        raise ValueError("Usa una ruta relativa como assets/productos/foto.webp.")
    if ".." in Path(value).parts or "\\" in value:
        raise ValueError("La ruta de imagen no es válida.")
    return value


def clean_item(kind, item):
    if not isinstance(item, dict):
        raise ValueError("Uno de los elementos no tiene un formato válido.")
    out = dict(item)
    key = "image" if kind in ("promotions", "founders") else "imagen"
    out[key] = safe_image_reference(out.get(key, ""))
    # Defensive cleanup: don't persist large browser-only payloads or accidental fields.
    for k, v in list(out.items()):
        if isinstance(v, str) and v.startswith("data:image/"):
            raise ValueError("Se encontró una imagen temporal en los datos. Vuelve a subirla desde el administrador.")
        if isinstance(v, str) and len(v) > 20000 and k not in ("description", "descripcion", "bio"):
            raise ValueError(f"El campo {k} es demasiado largo.")
    return out


def resolve_public_path(url_path):
    path = unquote(url_path.split("?", 1)[0]).lstrip("/")
    if not path:
        path = "index.html"
    path = path.replace("\\", "/")
    if path.startswith("assets/"):
        rel = Path(path[len("assets/"):])
        if ".." in rel.parts:
            return None
        candidate = (ASSETS_DIR / rel).resolve()
        if candidate != ASSETS_DIR and ASSETS_DIR not in candidate.parents:
            return None
        # If a cloud persistent disk is configured, still allow read-only images versioned
        # in the project repository when no upload with that path exists on the disk.
        if not candidate.is_file() and STORAGE_ROOT != ROOT:
            repo_candidate = (ROOT / "assets" / rel).resolve()
            if repo_candidate == (ROOT / "assets").resolve() or (ROOT / "assets").resolve() in repo_candidate.parents:
                if repo_candidate.is_file():
                    return repo_candidate
        return candidate
    candidate = (ROOT / path).resolve()
    if candidate != ROOT and ROOT not in candidate.parents:
        return None
    return candidate


class Handler(SimpleHTTPRequestHandler):
    server_version = "FarmaSaludLocal/1.0"

    def log_message(self, fmt, *args):
        print("[FarmaSalud] " + (fmt % args))

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header("Cache-Control", "no-store" if self.path.startswith("/api/") else "public, max-age=300")
        super().end_headers()

    def _cookies(self):
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except Exception:
            return None
        morsel = jar.get(SESSION_COOKIE)
        if not morsel:
            return None
        token = morsel.value
        expires = SESSIONS.get(token)
        if not expires or expires < time.time():
            SESSIONS.pop(token, None)
            return None
        return token

    def _is_admin(self):
        return self._cookies() is not None

    def _json(self, status, obj, extra_headers=None):
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > MAX_JSON_BYTES:
            raise ValueError("La solicitud está vacía o supera el tamaño permitido.")
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as ex:
            raise ValueError("El contenido enviado no es JSON válido.") from ex

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            return self._json(200, {"ok": True, "service": "FarmaSalud", "storage": "filesystem+json"})
        if parsed.path == "/api/admin/check":
            ok = self._is_admin()
            return self._json(200 if ok else 401, {"authenticated": ok})
        if parsed.path == "/api/state":
            state = read_state()
            if not self._is_admin():
                state["products"] = [p for p in state["products"] if p.get("activo", True) is not False]
                state["promotions"] = [p for p in state["promotions"] if p.get("active", False) is True]
                # Keep all six founder slots in order so a blank founder never shifts another profile.
            return self._json(200, state)
        if parsed.path == "/api/check-image":
            path = parse_qs(parsed.query).get("path", [""])[0]
            try:
                ref = safe_image_reference(path)
                if ref.startswith("https://"):
                    return self._json(200, {"exists": True, "path": ref})
                candidate = resolve_public_path(ref)
                exists = bool(candidate and candidate.is_file())
                return self._json(200 if exists else 404, {"exists": exists, "path": ref})
            except ValueError as ex:
                return self._json(400, {"error": str(ex)})
        # Serve project files, including image assets and JSON docs.
        candidate = resolve_public_path(parsed.path)
        requested = unquote(parsed.path).lstrip("/")
        internal = (candidate and (candidate.suffix.lower() in (".py", ".pyc") or ".before-api." in candidate.name or requested.startswith("data/")))
        if internal or not candidate or not candidate.is_file():
            return self._json(404, {"error": "Archivo no encontrado."}) if parsed.path.startswith("/api/") else self.send_error(404, "Archivo no encontrado.")
        ctype = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        try:
            blob = candidate.read_bytes()
        except OSError:
            return self.send_error(500, "No se pudo leer el archivo.")
        self.send_response(200)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if ctype.startswith("text/") or ctype in ("application/javascript", "application/json") else ""))
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def do_HEAD(self):
        parsed = urlparse(self.path)
        requested = unquote(parsed.path).lstrip("/")
        candidate = resolve_public_path(parsed.path)
        internal = (candidate and (candidate.suffix.lower() in (".py", ".pyc") or ".before-api." in candidate.name or requested.startswith("data/")))
        if candidate and candidate.is_file() and not internal:
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(candidate.name)[0] or "application/octet-stream")
            self.send_header("Content-Length", str(candidate.stat().st_size))
            self.end_headers()
        else:
            self.send_error(404, "Archivo no encontrado.")

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/admin/login":
            try:
                data = self._read_json()
            except ValueError as ex:
                return self._json(400, {"error": str(ex)})
            supplied = str(data.get("password", ""))
            if not hmac.compare_digest(supplied.encode("utf-8"), ADMIN_PASSWORD.encode("utf-8")):
                time.sleep(0.25)
                return self._json(401, {"error": "Contraseña incorrecta."})
            token = secrets.token_urlsafe(32)
            SESSIONS[token] = time.time() + 8 * 60 * 60
            secure = "; Secure" if self.headers.get("X-Forwarded-Proto", "http") == "https" else ""
            cookie = f"{SESSION_COOKIE}={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=28800" + secure
            return self._json(200, {"authenticated": True}, {"Set-Cookie": cookie})
        if parsed.path == "/api/admin/logout":
            token = self._cookies()
            if token:
                SESSIONS.pop(token, None)
            return self._json(200, {"ok": True}, {"Set-Cookie": f"{SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0"})
        if parsed.path == "/api/upload":
            if not self._is_admin():
                return self._json(401, {"error": "Inicia sesión como administrador para subir imágenes."})
            try:
                data = self._read_json()
                kind = str(data.get("kind", "" )).lower()
                folder = FOLDERS.get(kind)
                if not folder:
                    raise ValueError("Tipo de imagen no válido.")
                data_url = data.get("dataUrl")
                if not isinstance(data_url, str) or not data_url.startswith("data:image/"):
                    raise ValueError("No se recibió una imagen válida.")
                head, b64 = data_url.split(",", 1)
                mime_match = re.match(r"data:(image/[a-zA-Z0-9.+-]+);base64", head)
                if not mime_match:
                    raise ValueError("El formato de imagen no es válido.")
                mime = mime_match.group(1).lower()
                ext = ALLOWED_MIMES.get(mime)
                if not ext:
                    raise ValueError("Formato no permitido. Usa JPG, PNG, WEBP o GIF.")
                # estimate size before decoding to avoid oversized request payloads
                if len(b64) > (MAX_IMAGE_BYTES * 4 // 3 + 16):
                    raise ValueError("La imagen supera el límite de 10 MB.")
                try:
                    blob = base64.b64decode(b64, validate=True)
                except (binascii.Error, ValueError) as ex:
                    raise ValueError("No se pudo decodificar la imagen.") from ex
                if not blob or len(blob) > MAX_IMAGE_BYTES:
                    raise ValueError("La imagen está vacía o supera el límite de 10 MB.")
                # Validate file signature to avoid storing arbitrary files with image extensions.
                signatures = {
                    "image/jpeg": lambda b: b.startswith(b"\xff\xd8\xff"),
                    "image/png": lambda b: b.startswith(b"\x89PNG\r\n\x1a\n"),
                    "image/webp": lambda b: len(b) >= 12 and b[:4] == b"RIFF" and b[8:12] == b"WEBP",
                    "image/gif": lambda b: b[:6] in (b"GIF87a", b"GIF89a"),
                }
                if not signatures[mime](blob):
                    raise ValueError("El contenido del archivo no coincide con el tipo de imagen.")
                original_name = str(data.get("name", "imagen"))
                stem = Path(original_name).stem or original_name
                slug = re.sub(r"[^a-z0-9]+", "-", stem.lower()).strip("-")[:52] or "imagen"
                filename = f"{slug}-{time.strftime('%Y%m%d')}-{secrets.token_hex(3)}{ext}"
                target_dir = ASSETS_DIR / folder
                target_dir.mkdir(parents=True, exist_ok=True)
                target = target_dir / filename
                target.write_bytes(blob)
                rel = (Path("assets") / folder / filename).as_posix()
                return self._json(201, {"ok": True, "path": rel, "bytes": len(blob), "mime": mime})
            except ValueError as ex:
                return self._json(400, {"error": str(ex)})
            except Exception as ex:
                print("[FarmaSalud] upload error:", ex)
                return self._json(500, {"error": "No se pudo guardar la imagen en la carpeta del proyecto."})
        return self._json(404, {"error": "Endpoint no encontrado."})

    def do_PUT(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/state":
            return self._json(404, {"error": "Endpoint no encontrado."})
        if not self._is_admin():
            return self._json(401, {"error": "La sesión administrativa expiró. Vuelve a iniciar sesión."})
        try:
            payload = self._read_json()
            if not isinstance(payload, dict):
                raise ValueError("El formato de datos no es válido.")
            with LOCK:
                state = read_state()
                for key in ("products", "promotions", "founders"):
                    if key in payload:
                        if not isinstance(payload[key], list):
                            raise ValueError(f"La sección {key} debe ser una lista.")
                        if len(payload[key]) > 5000:
                            raise ValueError(f"La sección {key} tiene demasiados elementos.")
                        state[key] = [clean_item(key, item) for item in payload[key]]
                state["initialized"] = True
                write_state(state)
            # Update the response according to this authenticated session.
            return self._json(200, {"ok": True, **read_state()})
        except ValueError as ex:
            return self._json(400, {"error": str(ex)})
        except Exception as ex:
            print("[FarmaSalud] state error:", ex)
            return self._json(500, {"error": "No se pudieron guardar los datos. Revisa el servidor y vuelve a intentar."})


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("\nFarmaSalud está listo.")
    print(f"En esta computadora: http://127.0.0.1:{PORT}")
    print(f"En la red local: http://IP-DE-ESTA-COMPUTADORA:{PORT}")
    print("Carpeta de imágenes: assets/ | Datos: data/catalogo.json")
    if GENERATED_ADMIN_PASSWORD:
        print("CONTRASEÑA DE ADMINISTRADOR (guárdala en un lugar seguro):")
        print(ADMIN_PASSWORD)
        print("El servidor la guardó localmente en data/.admin_secret, archivo no accesible desde la web.")
    if not ENV_ADMIN_PASSWORD:
        print("Para publicar en Internet, define FARMASALUD_ADMIN_PASSWORD en la configuración del hosting.")
    print("Para detener el servidor, pulsa Ctrl+C.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServidor detenido.")
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
