from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = "django-insecure-reportlink-change-me-in-production"
DEBUG = True
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.postgres",
    "dashboard",
    "webpush",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "reportlink_backend.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "dashboard" / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "dashboard.templatetags.webpush_ctx.webpush_keys",
            ],
        },
    },
]

WSGI_APPLICATION = "reportlink_backend.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "reportlink",
        "USER": "postgres",
        "PASSWORD": "2Keroos@4",
        "HOST": "localhost",
        "PORT": "5432",
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "Africa/Nairobi"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "dashboard" / "static"]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LOGIN_URL = "/login/"
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/login/"

# --- Media files (user-uploaded content like profile pictures) ---
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

# Max upload size per file: 5 MB
DATA_UPLOAD_MAX_MEMORY_SIZE = 5 * 1024 * 1024
FILE_UPLOAD_MAX_MEMORY_SIZE = 5 * 1024 * 1024




# --- Web Push (browser notifications) ---
WEBPUSH_SETTINGS = {
    "VAPID_PUBLIC_KEY": "BKprGV5kci7U6zw-PTBTkGOh71o4ZYqEXMVaAgMESdnapmx6pT20RGzHVBojee0wPBMEZVc3iAasqArEkf1p6D4",
    "VAPID_PRIVATE_KEY": """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgfcEOrZku1nmLuJNm
e7NWX4/i0rEAkTBg3F0JBhdgfo+hRANCAASqaxleZHIu1Os8Pj0wU5Bjoe9aOGWK
hFzFWgIDBEnZ2qZseqU9tERsx1QaI3ntMDwTBGVXN4gGrKgKxJH9aeg+
-----END PRIVATE KEY-----""",
    "VAPID_ADMIN_EMAIL": "admin@reportlink.local",
}



