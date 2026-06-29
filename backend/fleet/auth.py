"""Authentification par token de chauffeur pour l'API d'ingestion.

En-tête attendu :  Authorization: Token <auth_token>
"""
from rest_framework import authentication, exceptions

from .models import Driver


class DriverTokenAuthentication(authentication.BaseAuthentication):
    keyword = "Token"

    def authenticate(self, request):
        header = authentication.get_authorization_header(request).split()
        if not header or header[0].lower() != self.keyword.lower().encode():
            return None
        if len(header) != 2:
            raise exceptions.AuthenticationFailed("En-tête Authorization invalide.")

        token = header[1].decode()
        try:
            driver = Driver.objects.get(auth_token=token, active=True)
        except Driver.DoesNotExist:
            raise exceptions.AuthenticationFailed("Token invalide ou chauffeur inactif.")

        return (driver, token)

    def authenticate_header(self, request):
        return self.keyword
