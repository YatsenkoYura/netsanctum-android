import 'dart:convert';

String buildWebAuthScript(String apiKey, String serverUrl) {
  final encodedApiKey = jsonEncode(apiKey);
  final serverUri = Uri.tryParse(serverUrl);
  final encodedServerOrigin = jsonEncode(
    serverUri != null && serverUri.hasAuthority ? serverUri.origin : '',
  );
  return '''
    (() => {
      const apiKey = $encodedApiKey;
      const authOrigin = $encodedServerOrigin;
      if (!apiKey || location.origin !== authOrigin) return;

      try {
        localStorage.setItem('X-API-Key', apiKey);
        window.X_API_KEY = apiKey;
      } catch (_) {}

      if (!window.__netOutpostAuthInstalled) {
        window.__netOutpostAuthInstalled = true;

        const originalFetch = window.fetch.bind(window);
        window.fetch = (input, init = {}) => {
          const requestUrl = new URL(input instanceof Request ? input.url : input, location.href);
          if (requestUrl.origin !== authOrigin) return originalFetch(input, init);
          const headers = new Headers(input instanceof Request ? input.headers : undefined);
          new Headers(init.headers || {}).forEach((value, name) => headers.set(name, value));
          headers.set('X-API-Key', apiKey);
          headers.set('Authorization', 'Bearer ' + apiKey);
          return originalFetch(input, { ...init, headers });
        };

        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(...args) {
          this.__netOutpostAuthenticated = new URL(args[1], location.href).origin === authOrigin;
          return originalOpen.apply(this, args);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          if (this.__netOutpostAuthenticated) {
            this.setRequestHeader('X-API-Key', apiKey);
            this.setRequestHeader('Authorization', 'Bearer ' + apiKey);
          }
          return originalSend.apply(this, args);
        };
      }
    })();
  ''';
}
