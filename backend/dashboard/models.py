from django.db import models
from django.contrib.postgres.fields import ArrayField


class User(models.Model):
    id = models.CharField(primary_key=True, max_length=64)
    full_name = models.CharField(max_length=200)
    phone = models.CharField(max_length=50, unique=True)
    email = models.CharField(max_length=200, unique=True)
    password_salt = models.CharField(max_length=200)
    password_hash = models.CharField(max_length=200)
    location = models.TextField(blank=True, default="")
    profile_info = models.TextField(blank=True, default="")
    created_at = models.DateTimeField()
    is_admin = models.BooleanField(default=False)
    profile_image_path = models.TextField(blank=True, null=True)

    class Meta:
        db_table = "users"
        managed = False

    def __str__(self):
        return f"{self.full_name} <{self.email}>"


class Report(models.Model):
    id = models.CharField(primary_key=True, max_length=64)
    user_id = models.CharField(max_length=64)
    report_type = models.CharField(max_length=100)
    category = models.CharField(max_length=100)
    subcategory = models.CharField(max_length=150)
    title = models.CharField(max_length=250)
    description = models.TextField()
    priority = models.CharField(max_length=30)
    contact = models.CharField(max_length=200, blank=True, default="")
    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)
    location_description = models.TextField(blank=True, default="")
    manual_area = models.CharField(max_length=200, blank=True, default="")
    manual_town = models.CharField(max_length=200, blank=True, default="")
    manual_parish = models.CharField(max_length=200, blank=True, default="")
    manual_district = models.CharField(max_length=200, blank=True, default="")
    manual_landmark = models.CharField(max_length=200, blank=True, default="")
    manual_directions = models.TextField(blank=True, default="")
    attachment_paths = ArrayField(models.TextField(), default=list, blank=True)
    status = models.CharField(max_length=30, default="pending")
    dynamic_fields = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField()
    updated_at = models.DateTimeField()

    class Meta:
        db_table = "reports"
        managed = False
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.id} - {self.title}"


class ReportUpdate(models.Model):
    id = models.BigAutoField(primary_key=True)
    report_id = models.CharField(max_length=64)
    status = models.CharField(max_length=30)
    description = models.TextField()
    timestamp = models.DateTimeField()

    class Meta:
        db_table = "report_updates"
        managed = False
        ordering = ["timestamp"]

    def __str__(self):
        return f"{self.report_id} -> {self.status}"


class Notification(models.Model):
    id = models.CharField(primary_key=True, max_length=64)
    user_id = models.CharField(max_length=64)
    title = models.CharField(max_length=250)
    message = models.TextField()
    type = models.CharField(max_length=50)
    report_id = models.CharField(max_length=64, null=True, blank=True)
    read = models.BooleanField(default=False)
    created_at = models.DateTimeField()

    class Meta:
        db_table = "notifications"
        managed = False
        ordering = ["-created_at"]

    def __str__(self):
        return self.title


class Category(models.Model):
    id = models.BigAutoField(primary_key=True)
    name = models.CharField(max_length=120, unique=True)
    description = models.TextField(blank=True, default="")
    icon = models.CharField(max_length=60, blank=True, default="fa-folder")
    color = models.CharField(max_length=20, blank=True, default="#E15712")
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "admin_categories"
        ordering = ["name"]

    def __str__(self):
        return self.name


class Location(models.Model):
    id = models.BigAutoField(primary_key=True)
    district = models.CharField(max_length=120)
    city_town = models.CharField(max_length=120, blank=True, default="")
    division = models.CharField(max_length=120, blank=True, default="")
    area = models.CharField(max_length=120, blank=True, default="")
    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "admin_locations"
        ordering = ["district", "city_town"]

    def __str__(self):
        return f"{self.district} / {self.city_town}".strip(" /")


class ActivityLog(models.Model):
    id = models.BigAutoField(primary_key=True)
    admin_username = models.CharField(max_length=120)
    action = models.CharField(max_length=80)
    description = models.TextField(blank=True, default="")
    ip_address = models.CharField(max_length=60, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "admin_activity_log"
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.admin_username}: {self.action}"


class Message(models.Model):
    id = models.BigAutoField(primary_key=True)
    user_id = models.CharField(max_length=64)
    sender = models.CharField(max_length=10)   # 'user' or 'admin'
    body = models.TextField()
    read = models.BooleanField(default=False)
    created_at = models.DateTimeField()

    class Meta:
        db_table = "messages"
        managed = False
        ordering = ["created_at"]

    def __str__(self):
        return f"{self.user_id} [{self.sender}] {self.body[:40]}"


class SystemSettings(models.Model):
    id = models.IntegerField(primary_key=True, default=1)
    app_name = models.CharField(max_length=120, default="ReportLink")
    support_email = models.CharField(max_length=200, blank=True, default="")
    support_phone = models.CharField(max_length=50, blank=True, default="")
    maintenance_mode = models.BooleanField(default=False)
    maintenance_message = models.TextField(
        default="The application is under maintenance. We apologize for the inconvenience."
    )
    emergency_number = models.CharField(max_length=40, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "system_settings"
        managed = False

    def __str__(self):
        return f"SystemSettings(maintenance={self.maintenance_mode})"

    @classmethod
    def get(cls):
        obj, _ = cls.objects.get_or_create(id=1)
        return obj


class NotificationComment(models.Model):
    id = models.BigAutoField(primary_key=True)
    notification_id = models.CharField(max_length=64)
    user_id = models.CharField(max_length=64)
    sender = models.CharField(max_length=10)   # 'user' or 'admin'
    body = models.TextField()
    created_at = models.DateTimeField()

    class Meta:
        db_table = "notification_comments"
        managed = False
        ordering = ["created_at"]

    def __str__(self):
        return f"{self.notification_id} [{self.sender}] {self.body[:40]}"

