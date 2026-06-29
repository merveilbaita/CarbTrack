"""WebSocket du dashboard : pousse positions + alertes en temps réel (staff only)."""
from channels.generic.websocket import AsyncJsonWebsocketConsumer

GROUP = "dashboard"


class DashboardConsumer(AsyncJsonWebsocketConsumer):
    async def connect(self):
        user = self.scope.get("user")
        if not (user and user.is_authenticated and user.is_staff):
            await self.close()
            return
        await self.channel_layer.group_add(GROUP, self.channel_name)
        await self.accept()

    async def disconnect(self, code):
        await self.channel_layer.group_discard(GROUP, self.channel_name)

    # Handlers de groupe (type "position.update" -> méthode position_update, etc.)
    async def position_update(self, event):
        await self.send_json({"kind": "position", **event["data"]})

    async def alert_new(self, event):
        await self.send_json({"kind": "alert", **event["data"]})
