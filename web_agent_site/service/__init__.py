"""HTTP service package for running WebShop as a separate environment server.

Import ``web_agent_site.service.api`` directly when you need the Flask app or
``WebShopService``.  Keeping this package initializer lightweight avoids loading
WebShop's optional runtime dependencies on a plain package import.
"""
