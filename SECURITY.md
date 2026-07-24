# Security

If you find a security issue in Rindo (the app or its build/release
pipeline), please report it privately rather than opening a public issue:
email daniel.hebberd@gmail.com, or use GitHub's "Report a vulnerability"
(Security tab) if enabled.

The app talks only to the public data endpoints listed in the README (JMA,
JARTIC, MLIT, map tile servers, and the on-device ML Kit model download);
it stores no accounts or personal data beyond device-local preferences and
GPS position used for display.
