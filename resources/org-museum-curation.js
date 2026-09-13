(function () {
  "use strict";

  var storageKey = "org-museum-curation-token";
  var prefix = storageKey + "=";
  var token = "";

  if (location.hash.slice(1).indexOf(prefix) === 0) {
    token = decodeURIComponent(location.hash.slice(prefix.length + 1));
    try { sessionStorage.setItem(storageKey, token); } catch (_error) {}
    history.replaceState(history.state, "", location.pathname + location.search);
  } else {
    try { token = sessionStorage.getItem(storageKey) || ""; } catch (_error) {}
  }

  if (!token) return;

  function api(path, options) {
    options = options || {};
    var headers = Object.assign({
      "Authorization": "Bearer " + token,
      "X-Org-Museum-Curation": "1"
    }, options.headers || {});
    return fetch("/api/v1/" + path, Object.assign({}, options, { headers: headers }))
      .then(function (response) {
        return response.json().catch(function () { return {}; }).then(function (payload) {
          if (!response.ok || payload.ok === false) throw new Error(payload.error || "策展请求失败");
          return payload;
        });
      });
  }

  window.orgMuseumCurationSubmit = function (config, relation, transaction) {
    if (transaction) {
      return api("apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          schemaVersion: 1,
          transactionId: transaction.transactionId,
          confirmIdentity: false
        })
      });
    }
    return api("page?pageId=" + encodeURIComponent(config.sourceId)).then(function (page) {
      return api("preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          schemaVersion: 1,
          pageId: config.sourceId,
          expectedSha256: page.sha256,
          changes: {},
          relations: [relation]
        })
      });
    });
  };

  if (window.orgMuseumCuration) window.orgMuseumCuration.mode = "loopback";
})();
