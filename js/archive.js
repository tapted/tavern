/**
 * JS Helpers for interacting with the JSZip library.
 */
var Archive = (function() {
  /** @private */
  function saveDirs(dest, dirs, onComplete) {
    if (dirs.length == 0) {
      onComplete(true);
      return;
    }

    var dir = dirs.pop();
    dest.getDirectory(dir.name, {create: true, exclusive: true}, function() {
      saveDirs(dest, dirs, onComplete);
    });
  }

  /** @private */
  function saveFiles(dest, files, onComplete) {
    if (files.length == 0) {
      onComplete(true);
      return;
    }

    var file = files.pop();
    dest.getFile(file.name, {create: true, exclusive: true}, function(entry) {
      entry.createWriter(function(writer) {
        writer.onwriteend = function() {
          saveFiles(dest, files, onComplete);
        };
        writer.onerror = function(e) {
          console.log('Write failed: ', e);
          onComplete(false);
        };

        writer.seek(0);
        writer.write(new Blob([file.asArrayBuffer()]));
      });
    });
  }

  /**
   * Asynchronously extract an uncompressed .zip archive to |dest|.
   *
   * @param {ArrayBuffer} data Uncompressed zip data, residing in memory.
   * @param {DirectoryEntry} dest Directory to extract the archive.
   * @param {function(boolean)} onFinish Called when finished; false on failure.
   */
  function extractZipFile(data, dest, onFinish) {
    // Sometimes data arrives as a DartObject (by mistake?).
    if (data.o != null)
      data = data.o;
    if (dest.o != null)
      dest = dest.o;

    var zip = new JSZip(data);

    files = zip.file(/.*/);
    folders = zip.folder(/.*/);

    saveDirs(dest, folders, function(success) {
      if (!success) {
        onFinish(false);
        return;
      }

      saveFiles(dest, files, function(success) {
        onFinish(success);
      });
    });
  }

  return { extractZipFile : extractZipFile };
})();
