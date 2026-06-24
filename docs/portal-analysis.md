# Telecom Ruijie Portal Notes

The new portal redirects captive HTTP traffic through this chain:

```text
http://example.com/
  -> http://110.184.24.61/eportal/index.jsp?userip=...&nasip=...&wlanparameter=...&url=...
  -> http://110.184.24.61/portal/portal-main?sessionId=...&userIp=...&nasIp=...&customPageId=...
  -> /cas-sso/login?flowSessionId=...&customPageId=...&userIp=...&nasIp=...&nodeMac=...
```

The actual username/password form is served by the CAS SSO page, not by the legacy
`/eportal/InterFace.do?method=login` endpoint.

Important hidden fields from the CAS page:

- `login-croypto`: base64 AES key.
- `login-page-flowkey`: Spring WebFlow execution token.
- `current-login-type`: normally `UsernamePassword`.

The client submits:

- `username`: account name.
- `password`: AES-ECB-PKCS7 encrypted password, base64 encoded.
- `croypto`: copied from `login-croypto`.
- `execution`: copied from `login-page-flowkey`.
- `type`: `UsernamePassword`.
- `_eventId`: `submit`.
- `captcha_payload`: AES-ECB-PKCS7 encrypted `{}`, base64 encoded.

A successful login returns a `302` redirect to:

```text
/portal/assets/auth-success.html?ticket=ST-...
```

The Go client keeps the legacy eportal login path as a fallback when the redirect chain
does not end at `/portal/portal-main`.
