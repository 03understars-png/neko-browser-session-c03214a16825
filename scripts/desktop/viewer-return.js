(function () {
  var AWAY_MS = 5000;
  var peers = [];
  var channels = [];
  var Native = window.RTCPeerConnection;
  if (Native) {
    var Tracked = function (config) {
      var peer = new Native(config);
      peers.push(peer);
      var create = peer.createDataChannel.bind(peer);
      peer.createDataChannel = function () {
        var channel = create.apply(null, arguments);
        channels.push(channel);
        return channel;
      };
      peer.addEventListener("datachannel", function (event) { channels.push(event.channel); });
      return peer;
    };
    Tracked.prototype = Native.prototype;
    Object.setPrototypeOf(Tracked, Native);
    window.RTCPeerConnection = Tracked;
  }

  function received(peer) {
    return peer.getStats().then(function (stats) {
      var bytes = 0;
      stats.forEach(function (report) {
        if (report.type === "inbound-rtp" && report.kind === "video") bytes += report.bytesReceived || 0;
      });
      return bytes;
    });
  }

  function broken() {
    var live = peers.filter(function (peer) { return peer.connectionState !== "closed"; });
    if (!live.length) return Promise.resolve(false);  // not streaming over WebRTC: nothing to judge
    var peer = live[live.length - 1];
    if (peer.connectionState !== "connected") return Promise.resolve(true);
    var shut = channels.some(function (channel) { return channel.readyState === "closed" || channel.readyState === "closing"; });
    if (shut) return Promise.resolve(true);
    return received(peer).then(function (before) {
      return new Promise(function (resolve) { setTimeout(resolve, 2500); }).then(function () {
        return received(peer).then(function (after) { return after <= before; });
      });
    });
  }

  var chain = new URLSearchParams(location.search).get("cb_chain");
  if (chain && /^https:\/\//.test(chain)) {
    var strikes = 0;
    var sockets = [];
    var NativeSocket = window.WebSocket;
    if (NativeSocket) {
      var TrackedSocket = function (url, protocols) {
        var socket = protocols === undefined ? new NativeSocket(url) : new NativeSocket(url, protocols);
        sockets.push(socket);
        return socket;
      };
      TrackedSocket.prototype = NativeSocket.prototype;
      Object.setPrototypeOf(TrackedSocket, NativeSocket);
      window.WebSocket = TrackedSocket;
    }
    var gone = function () {
      var last = sockets[sockets.length - 1];
      if (last && last.readyState === 3) return Promise.resolve(true);
      return broken();
    };
    setInterval(function () {
      if (document.visibilityState !== "visible" || !/stream\.html$/.test(location.pathname)) return;
      gone().then(function (yes) {
        strikes = yes ? strikes + 1 : 0;
        if (strikes >= 3) location.href = chain;
      }, function () {});
    }, 10000);
  }

  var hiddenAt = 0;
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      hiddenAt = Date.now();
      return;
    }
    var away = hiddenAt && Date.now() - hiddenAt > AWAY_MS;
    hiddenAt = 0;
    if (!away || !/stream\.html$/.test(location.pathname)) return;
    setTimeout(function () {
      if (document.visibilityState !== "visible") return;
      broken().then(function (yes) { if (yes) location.reload(); }, function () {});
    }, 3000);
  });
})();
