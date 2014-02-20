function createLogWindow(callback) {
  chrome.app.window.create('packages/tavern/tavern_log.html', {id: 'tavern'},
    function (appWindow) {
      appWindow.contentWindow.document.addEventListener(
          'DOMContentLoaded', callback, false);
    });
}

function logMessage(line, level) {
  var logWindow = chrome.app.window.get('tavern');
  if (logWindow == null)
    return createLogWindow(function() { logMessage(line, level); });
  var newMessage =
      '<div class="log log_' + escape(level) + '">' + escape(line) + '</div>';
  var logtext = logWindow.contentWindow.document.getElementById('logtext');
  logtext.innerHTML += newMessage;
}
