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

In the OpenWrt wrapper, CT/Ruijie authentication defaults to an HTTP captive
portal probe, currently `http://connectivitycheck.gstatic.com/generate_204`.
The access gateway intercepts unauthenticated HTTP traffic and returns the
current portal redirect chain. The client follows that chain and switches to
CAS/Ruijie login only after it reaches `/portal/portal-main`; directly using the
CAS host can miss the redirect parameters required to build the login URL. The
old dormitory entry host `172.25.249.64` is retained only as a legacy option.
For clarity, the LuCI UI exposes this path as `ct` only; older `ct_ruijie` and
`qsh-telecom-ruijie` values are treated as compatibility aliases by the scripts.

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
