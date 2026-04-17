class MediaSnifferJs {
  static const String snifferScript = '''
      window.Flutter = window.Flutter || { postMessage: function(m){ try { if(window.flutter_inappwebview && window.flutter_inappwebview.callHandler) window.flutter_inappwebview.callHandler('Flutter', m); } catch(e){} } };
      window.MediaInterceptor = window.MediaInterceptor || {
        processedUrls: new Set(),
        interceptedRequests: new Map(),
        blobUrls: new Map(),
        m3u8Segments: new Map(),
        mediaElements: new Set(),
        shadowRoots: new Set(),
        iframeContents: new Set(),
        dynamicContent: new Set()
      };

      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      function isApiUrl(url) {
        if (!url) return false;
        if (url.startsWith('blob:') || url.startsWith('data:')) return false;
        const lower = url.toLowerCase();
        try {
          const u = new URL(url);
          const path = u.pathname.toLowerCase();
          const host = u.hostname.toLowerCase();
          const hasMediaExt = /\\.(jpg|jpeg|png|gif|webp|mp4|webm|mov|m3u8|ts|mp3|m4a)(\\?|\$)/.test(path);
          if (hasMediaExt) return false;
          const videoSiteHosts = ['tik.', 'porn', 'xvideos', 'xhamster', 'pornhub', 'redtube', 'cdn.', 'stream', 'video.', 'media.'];
          if (videoSiteHosts.some(h => host.includes(h))) return false;
          const apiPatterns = [
            'detailrecommend', 'wisesearchsetpic', 'wisejson',
            'getrelatedvideos', 'getuserbyslug', '/graphql', '/v1/', '/v2/', '/v3/',
            '/models', '/model/', '/slug', '/users/', '/search?', '/query', '/rest/', '/endpoint', '/service',
            'getuser', 'getpost', 'comment', 'like', 'share', 'follow', 'unfollow', 'subscribe'
          ];
          if (apiPatterns.some(p => lower.includes(p))) return true;
          const looksLikeApi = /\\/(get|post|api|graphql|rest|v1|v2|models|user|slug)/.test(path);
          if (looksLikeApi) return true;
        } catch (e) {}
        return false;
      }

      function isMediaUrl(url) {
        if (!url) return false;
        if (isApiUrl(url)) return false;
        const mediaExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.mp4', '.webm', '.mov', '.m3u8', '.ts', '.mp3', '.m4a'];
        const lowerUrl = url.toLowerCase();
        if (mediaExtensions.some(ext => lowerUrl.includes(ext))) return true;
        const trustedPatterns = ['/cdn.', '/static/', '/assets/', '/uploads/', '/media/', '/images/', '/videos/', '/stream', 'youtube.com', 'youtu.be'];
        if (trustedPatterns.some(p => lowerUrl.includes(p))) return true;
        return false;
      }

      function extractBase64FromDataUrl(dataUrl) {
        if (!dataUrl || typeof dataUrl !== 'string') return null;
        const idx = dataUrl.indexOf(';base64,');
        if (idx >= 0) return dataUrl.substring(idx + 8);
        const parts = dataUrl.split(',');
        return parts.length > 1 ? parts[parts.length - 1] : null;
      }

      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          let blob;
          try {
            const resp = await fetch(blobUrl, { method: 'GET', credentials: 'omit', cache: 'no-cache' });
            if (!resp.ok) throw new Error('Fetch status ' + resp.status);
            blob = await resp.blob();
          } catch (e) {
            blob = await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open('GET', blobUrl, true);
              xhr.responseType = 'blob';
              xhr.onload = () => xhr.status >= 200 && xhr.status < 300 ? resolve(xhr.response) : reject(new Error('XHR status ' + xhr.status));
              xhr.onerror = () => reject(new Error('XHR error'));
              xhr.send();
            });
          }
          if (!blob || blob.size === 0) throw new Error('Empty blob');
          const reader = new FileReader();
          return new Promise((resolve, reject) => {
            reader.onloadend = () => {
              const b64 = extractBase64FromDataUrl(reader.result);
              b64 ? resolve({ resolvedUrl: b64, isBase64: true, mediaType: mediaType }) : reject(new Error('No base64 data'));
            };
            reader.onerror = () => reject(new Error('FileReader error'));
            reader.readAsDataURL(blob);
          });
        } catch (e) { return null; }
      }

      (function() {
        const originalXHROpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
          this._interceptedUrl = url;
          this._interceptedMethod = method;
          return originalXHROpen.apply(this, arguments);
        };
        const originalXHRSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
          const url = this._interceptedUrl;
          if (url && !isApiUrl(url) && (isMediaUrl(url) || /\\.(ts|m4s|mp4|webm)(\\?|\$)/i.test(url))) {
            window.MediaInterceptor.interceptedRequests.set(url, { method: this._interceptedMethod, timestamp: Date.now(), type: 'xhr' });
          }
          return originalXHRSend.apply(this, arguments);
        };
        const originalFetch = window.fetch;
        window.fetch = async function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url);
          const resp = await originalFetch.apply(this, arguments);
          if (url && resp && resp.ok) {
            const ct = (resp.headers.get('content-type') || '').toLowerCase();
            if (ct.startsWith('video/') || ct.startsWith('image/') || ct.includes('mpegurl') || ct.includes('m3u8') || isMediaUrl(url)) {
              window.MediaInterceptor.interceptedRequests.set(url, { method: (init && init.method) || 'GET', timestamp: Date.now(), type: 'fetch', contentType: ct });
            }
          }
          return resp;
        };
      })();

      function markMediaUrlProcessing(url) {
        if (!url || window.MediaInterceptor.processedUrls.has(url)) return false;
        window.MediaInterceptor.processedUrls.add(url);
        setTimeout(() => window.MediaInterceptor.processedUrls.delete(url), 45000);
        return true;
      }

      document.addEventListener('touchstart', function(e) {
        const target = e.target.closest('video, img, a[href*=".mp4"], a[href*=".jpg"], [style*="background-image: url"]');
        if (target) {
          const touch = e.touches[0];
          window._lastTouchX = touch.clientX;
          window._lastTouchY = touch.clientY;
          window._pressTimer = setTimeout(() => handleMediaDownload(target, e), 400);
        }
      }, true);

      document.addEventListener('touchmove', () => clearTimeout(window._pressTimer), true);
      document.addEventListener('touchend', () => clearTimeout(window._pressTimer), true);

      async function handleMediaDownload(target, e) {
        let url = target.currentSrc || target.src || target.href;
        if (!url && target.style.backgroundImage) {
          const m = target.style.backgroundImage.match(/url\(['"]?([^'")]+)['"]?\)/);
          if (m) url = m[1];
        }
        if (!url) return;
        if (!markMediaUrlProcessing(url)) return;
        
        if (isBlobUrl(url)) {
          const resolved = await resolveBlobUrl(url, 'video');
          if (resolved) {
            Flutter.postMessage(JSON.stringify({ type: 'media', action: 'download', url: resolved.resolvedUrl, isBase64: true, mediaType: resolved.mediaType }));
          }
        } else {
          Flutter.postMessage(JSON.stringify({ type: 'media', action: 'download', url: url, isBase64: false, mediaType: 'video' }));
        }
      }
  ''';
}
