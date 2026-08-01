# Security

If you find a security issue in Rindo, report it privately. Do not open a
public issue. This covers the app and the build and release pipeline.
Email daniel.hebberd@gmail.com, or use GitHub's 'Report a vulnerability'
button on the Security tab if it is enabled.

The app talks only to the public data endpoints listed in the README: JMA,
JARTIC, MLIT, the map tile servers and the on-device ML Kit model
download. It holds no accounts and no personal data. The only things it
keeps are device-local preferences and the GPS position it needs to draw
the map.
