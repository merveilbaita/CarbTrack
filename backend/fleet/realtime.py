"""Diffusion temps réel vers le groupe WebSocket du dashboard (best-effort)."""
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer


def _send(message_type: str, data: dict):
    try:
        layer = get_channel_layer()
        if layer is None:
            return
        async_to_sync(layer.group_send)(
            "dashboard", {"type": message_type, "data": data}
        )
    except Exception:
        # L'ingestion ne doit jamais échouer si Redis/Channels est indisponible.
        pass


def broadcast_position(data: dict):
    _send("position.update", data)


def broadcast_alert(data: dict):
    _send("alert.new", data)
