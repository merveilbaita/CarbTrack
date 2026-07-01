from django import forms
from django.contrib import admin
from django.contrib.gis.admin import GISModelAdmin

from .models import Alert, Appro, Assignment, Driver, Position, Route, Vehicle


class DriverAdminForm(forms.ModelForm):
    """Permet de saisir un PIN en clair (haché à l'enregistrement)."""

    pin = forms.CharField(
        label="Code PIN",
        required=False,
        widget=forms.PasswordInput(render_value=False),
        help_text="À la création : définit le PIN. À l'édition : laisser vide pour "
        "conserver le PIN actuel.",
    )

    class Meta:
        model = Driver
        fields = ("name", "phone", "vehicle", "role", "active")

    def save(self, commit=True):
        driver = super().save(commit=False)
        pin = self.cleaned_data.get("pin")
        if pin:
            driver.set_pin(pin)
        if commit:
            driver.save()
        return driver


@admin.register(Driver)
class DriverAdmin(admin.ModelAdmin):
    form = DriverAdminForm
    list_display = ("name", "phone", "role", "vehicle", "has_pin", "active", "created_at")
    list_filter = ("role", "active", "vehicle")
    search_fields = ("name", "phone")
    readonly_fields = ("auth_token", "created_at")
    fields = ("name", "phone", "vehicle", "role", "pin", "active", "auth_token", "created_at")

    @admin.display(boolean=True, description="PIN défini")
    def has_pin(self, obj):
        return bool(obj.pin_hash)


@admin.register(Vehicle)
class VehicleAdmin(admin.ModelAdmin):
    list_display = ("identifier", "label", "active")
    search_fields = ("identifier", "label")


@admin.register(Route)
class RouteAdmin(GISModelAdmin):
    list_display = ("name", "corridor_m", "active", "created_at")


@admin.register(Assignment)
class AssignmentAdmin(admin.ModelAdmin):
    list_display = ("driver", "vehicle", "route", "start_at", "end_at")
    list_filter = ("route",)


@admin.register(Position)
class PositionAdmin(GISModelAdmin):
    list_display = ("driver", "vehicle", "recorded_at", "off_route", "dist_m")
    list_filter = ("off_route", "driver")
    readonly_fields = ("created_at",)


@admin.register(Alert)
class AlertAdmin(admin.ModelAdmin):
    list_display = ("kind", "driver", "vehicle", "created_at", "acked_at")
    list_filter = ("kind", "acked_at")


@admin.register(Appro)
class ApproAdmin(admin.ModelAdmin):
    list_display = ("date", "driver", "vehicle", "qte_litres", "difference", "created_at")
    list_filter = ("driver", "vehicle", "date")
    readonly_fields = ("difference", "created_at")
