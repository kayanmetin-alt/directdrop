/* DirectDrop site dil yönetimi.
 * Cihaz dili Türkçe ise Türkçe, değilse İngilizce seçilir.
 * Kullanıcı seçimi localStorage'da saklanır. */
(function () {
  var KEY = 'dd-lang';

  function detect() {
    try {
      var saved = localStorage.getItem(KEY);
      if (saved === 'tr' || saved === 'en') return saved;
    } catch (e) {}
    var langs = navigator.languages || [navigator.language || navigator.userLanguage || 'en'];
    for (var i = 0; i < langs.length; i++) {
      if ((langs[i] || '').toLowerCase().indexOf('tr') === 0) return 'tr';
    }
    return 'en';
  }

  function apply(lang) {
    var html = document.documentElement;
    html.classList.remove('lang-tr', 'lang-en');
    html.classList.add('lang-' + lang);
    html.setAttribute('lang', lang);

    var title = html.getAttribute('data-title-' + lang);
    if (title) document.title = title;

    var buttons = document.querySelectorAll('[data-set-lang]');
    for (var i = 0; i < buttons.length; i++) {
      var active = buttons[i].getAttribute('data-set-lang') === lang;
      buttons[i].classList.toggle('active', active);
    }
    try { localStorage.setItem(KEY, lang); } catch (e) {}
  }

  // Sayfa boyanmadan önce dili uygula (titreşim olmaz).
  apply(detect());

  document.addEventListener('DOMContentLoaded', function () {
    var buttons = document.querySelectorAll('[data-set-lang]');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener('click', function (e) {
        e.preventDefault();
        apply(this.getAttribute('data-set-lang'));
      });
    }
    apply(document.documentElement.classList.contains('lang-tr') ? 'tr' : 'en');
  });
})();
