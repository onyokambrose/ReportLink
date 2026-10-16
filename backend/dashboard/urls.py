from django.urls import path
from . import views

app_name = "dashboard"

urlpatterns = [
    path("login/", views.login_view, name="login"),
    path("logout/", views.logout_view, name="logout"),
    path("", views.dashboard_home, name="home"),
    path("reports/", views.report_list, name="report_list"),
    path("reports/<str:report_id>/", views.report_detail, name="report_detail"),
    path("reports/<str:report_id>/action/<str:action>/", views.report_action, name="report_action"),
    path("users/", views.user_list, name="user_list"),
    path("users/<str:user_id>/", views.user_detail, name="user_detail"),
    path("messages/", views.message_inbox, name="message_inbox"),
    path("messages/<str:user_id>/", views.message_thread, name="message_thread"),
    path("messages/<str:user_id>/send/", views.message_send, name="message_send"),
    path("activity/", views.activity_log, name="activity_log"),
    path("settings/", views.settings_page, name="settings_page"),
    path("settings/save/", views.settings_save, name="settings_save"),

    # Categories
    path("categories/", views.category_list, name="category_list"),
    path("categories/new/", views.category_create, name="category_create"),
    path("categories/<int:cat_id>/edit/", views.category_edit, name="category_edit"),
    path("categories/<int:cat_id>/delete/", views.category_delete, name="category_delete"),
    path("categories/<int:cat_id>/toggle/", views.category_toggle, name="category_toggle"),

    # Locations
    path("locations/", views.location_list, name="location_list"),
    path("locations/new/", views.location_create, name="location_create"),
    path("locations/<int:loc_id>/edit/", views.location_edit, name="location_edit"),
    path("locations/<int:loc_id>/delete/", views.location_delete, name="location_delete"),

    # Notifications list
    path("notifications/", views.notification_list, name="notification_list"),
    path("notifications/broadcast/", views.notification_broadcast, name="notification_broadcast"),

    # Notification thread (admin view)
    path("notifications/<str:notification_id>/", views.notification_detail, name="notification_detail"),
    path("notifications/<str:notification_id>/comment/", views.notification_comment_post, name="notification_comment_post"),

    # API
    path("api/upload-profile/<str:user_id>/", views.api_upload_profile_image, name="api_upload_profile"),
    path("api/profile-image/<str:user_id>/", views.api_get_profile_image, name="api_profile_image"),
    path("api/public-settings/", views.api_public_settings, name="api_public_settings"),
    path("api/notifications/<str:notification_id>/comments/", views.api_notification_comments, name="api_notification_comments"),
    path("api/notifications/<str:notification_id>/comments/post/", views.api_notification_comment_post, name="api_notification_comment_post"),
    path("webpush/subscribe/", views.webpush_subscribe, name="webpush_subscribe"),
]


