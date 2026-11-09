// Shrinks photos on the phone before they upload: max 1600px, saved as JPEG.
// Makes uploads fast on site and turns iPhone HEIC photos into JPEGs every browser can show.
(function () {
  var MAX = 1600;
  if (!window.DataTransfer || !window.createImageBitmap) return;

  function shrink(file) {
    if (!/^image\//.test(file.type) || file.type === 'image/gif') return Promise.resolve(file);
    return createImageBitmap(file).then(function (bmp) {
      var scale = Math.min(1, MAX / Math.max(bmp.width, bmp.height));
      var w = Math.round(bmp.width * scale);
      var h = Math.round(bmp.height * scale);
      var canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      canvas.getContext('2d').drawImage(bmp, 0, 0, w, h);
      return new Promise(function (resolve) {
        canvas.toBlob(function (blob) {
          if (!blob || blob.size >= file.size) return resolve(file);
          var name = file.name.replace(/\.[^.]+$/, '') + '.jpg';
          resolve(new File([blob], name, { type: 'image/jpeg', lastModified: Date.now() }));
        }, 'image/jpeg', 0.82);
      });
    }).catch(function () { return file; });
  }

  document.addEventListener('change', function (e) {
    var input = e.target;
    if (!input.matches || !input.matches('input[type=file][data-shrink]') || input.dataset.busy) return;
    var files = Array.prototype.slice.call(input.files || []);
    if (!files.length) return;
    var form = input.form;
    var buttons = form ? form.querySelectorAll('button') : [];
    input.dataset.busy = '1';
    buttons.forEach(function (b) { b.disabled = true; });
    var note = document.createElement('p');
    note.className = 'hint';
    note.textContent = 'Preparing photos…';
    input.insertAdjacentElement('afterend', note);
    Promise.all(files.map(shrink)).then(function (out) {
      var dt = new DataTransfer();
      out.forEach(function (f) { dt.items.add(f); });
      input.files = dt.files;
    }).finally(function () {
      delete input.dataset.busy;
      buttons.forEach(function (b) { b.disabled = false; });
      note.textContent = files.length + ' photo' + (files.length === 1 ? '' : 's') + ' ready';
    });
  });
})();
