/* סימן — כפתור "חזרה" של הטלפון (5.2.7)
   לחיצה על "חזרה" (או החלקת חזרה באנדרואיד) לוקחת צעד אחד אחורה בתוך סימן ולא סוגרת את האפליקציה:
   1. חלון, תפריט או חלונית פתוחים — נסגרים (העליון קודם), בדיוק כמו Esc או ×
   2. העורכים (Word / Excel / PowerPoint) — קודם נסגר מה שפתוח בתוכם, אחר כך העורך עצמו (עם השאלה על שינויים שלא נשמרו)
   3. תמלול — מהמסמך לספרייה, מהספרייה למסך הראשי, ומשם חזרה לסימן
   4. הקראה פעילה — נעצרת
   5. כלי פעיל על ה-PDF (עט, מרקר, טקסט...) — חוזרים לכלי הבחירה
   6. קובץ פתוח — נסגר (עם השאלה על שינויים שלא נשמרו) וחוזרים לקובץ הקודם או למסך הפתיחה
   7. במסך הפתיחה — הודעה "לחצו שוב כדי לצאת", ולחיצה שנייה תוך 2.5 שניות יוצאת
   במחשב זה עובד גם עם כפתור "אחורה" של הדפדפן ושל העכבר. */
(function () {
  'use strict';
  if (window.__simanBack) return; window.__simanBack = true;

  const $ = id => document.getElementById(id);
  const norm = s => (s || '').replace(/\s+/g, ' ').trim();
  const say = m => { try { if (typeof toast === 'function') toast(m); } catch (_) {} };

  /* ---------- the extra history step that catches "back" ---------- */
  let guarded = false, exitT = 0, handling = false;
  function guard() {
    if (guarded) return;
    try { history.pushState({ simanBack: 1 }, ''); guarded = true; } catch (_) {}
  }
  // the browser only honours a step added after the user touched the app, so it is added on the first touch / key
  ['pointerdown', 'touchstart', 'keydown'].forEach(ev => addEventListener(ev, guard, { capture: true, passive: true }));

  addEventListener('popstate', () => {
    guarded = false; clearTimeout(exitT);
    if (handling) { guard(); return; }
    handling = true;
    let did = false;
    try { did = stepBack(); } catch (e) { console.error(e); did = true; }
    finally { setTimeout(() => { handling = false; }, 150); }
    if (did) guard();
    else {
      say('לחצו שוב על "חזרה" כדי לצאת מסימן');
      exitT = setTimeout(guard, 2500); // no second press: back to normal
    }
  });

  /* ---------- what counts as open ---------- */
  function shown(el) {
    if (!el || !el.isConnected) return false;
    if (el.closest('[hidden]') && !(el.tagName === 'DIALOG' && el.open)) return false;
    if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    if (r.right <= 0 || r.bottom <= 0 || r.left >= innerWidth || r.top >= innerHeight) return false;
    return true;
  }
  // small things that may simply be hidden if they ignore Esc
  const LIGHT = ['.sp-save', '#saveMenu', '.tab-menu', '.oa-menu', '.oa-drop', '#wePop', '#xePop', '#pePop', '#weFind', '#xeFind', '#weImgBox', '[role="menu"]'].join(',');
  const HEAVY = ['dialog[open]', '[role="dialog"]', '#wed', '#xed', '#ped', '#weDlg', '#xeDlg', '#peDlg', '.pe-play',
    '#tpanel', '#pgpanel', '#aiPanel', '#a11yPanel', '#admPanel', '#snd', '#vx', '.otr-dlg'].join(',');
  const NEVER = '#toast, #busy, .sp-note, #intro, #printArea, #tools, #tabs, .ra';
  // the editors' own close buttons (they may be hidden by the phone layout, a click still works)
  const CLOSE_ID = { wed: 'weClose', xed: 'xeClose', ped: 'peClose', tpanel: 'tpClose', pgpanel: 'pgClose', aiPanel: 'aiClose',
    admPanel: 'admClose', weFind: 'weFindX', xeFind: 'xeFindX' };

  const isModal = el => { try { return el.tagName === 'DIALOG' && el.matches(':modal'); } catch (_) { return false; } };
  function zOf(el) {
    let z = 0;
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.position !== 'static') { const v = parseInt(cs.zIndex, 10); if (!isNaN(v)) z = v; }
    }
    return z;
  }
  function topLayer() {
    let list = [...document.querySelectorAll(LIGHT + ',' + HEAVY)].filter(el => !el.matches(NEVER) && shown(el));
    list = list.filter(a => !list.some(b => b !== a && a.contains(b))); // the innermost one is the one in front
    if (!list.length) return null;
    const modal = list.filter(isModal);
    if (modal.length) return modal.find(d => d.contains(document.activeElement)) || modal[modal.length - 1];
    list.sort((a, b) => (zOf(a) - zOf(b)) || (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
    return list[list.length - 1];
  }

  /* ---------- closing one thing ---------- */
  function scoreBtn(b) {
    if (b.closest('[role="toolbar"], .oa-qat, #weRibbon, #xeRibbon, #peRibbon')) return 0; // undo / redo live there
    if (b.matches('.warn, .danger, .pri, .primary')) return 0;
    const id = b.id || '', all = [norm(b.getAttribute('aria-label')), norm(b.title), norm(b.textContent)];
    if (all.some(s => /Ctrl|בלי לשמור|מחיק|למחוק|שמירה|שליחה|אישור/.test(s))) return 0;
    if (/Back$/.test(id) || all.some(s => s === 'חזרה')) return 4;
    if (all.some(s => s === 'ביטול')) return 3;
    if (/(Close|X)$/.test(id) || b.matches('[data-x], [data-a="close"], .we-x, .xe-x, .pe-x, .s-x') ||
        all.some(s => s === 'סגירה' || /^סגירת /.test(s) || /^חזרה ל/.test(s) || /^[×✕✖]$/.test(s))) return 2;
    return 0;
  }
  function bestButton(L) {
    let best = null, bs = 0;
    for (const b of L.querySelectorAll('button, [role="button"]')) {
      if (b.disabled || !shown(b)) continue;
      const s = scoreBtn(b); if (s > bs) { bs = s; best = b; }
    }
    return best;
  }
  function pressEsc(L) {
    const a = document.activeElement;
    const t = (a && a !== document.body && L.contains(a)) ? a : ([...L.querySelectorAll('button')].find(shown) || L);
    t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true }));
  }
  function voiceBack(root) {
    const on = root.querySelector('.vx-screen.on'), id = on && on.id;
    const go = v => { const b = root.querySelector(`.vx-nav [data-v="${v}"]`) || root.querySelector(`[data-v="${v}"]`); if (b && shown(b)) { b.click(); return true; } return false; };
    if (id === 'vxDoc' && go('lib')) return true;
    if (id === 'vxLib' && go('new')) return true;
    if (id === 'vxRec') { const rb = $('vxRecBack'); if (rb && shown(rb)) { rb.click(); return true; } }
    const c = root.querySelector('[data-a="close"]'); // asks first if a recording / transcription is still running
    if (c) c.click(); else pressEsc(root);
    return true;
  }
  function closeLayer(L) {
    if (L.id === 'vx') return voiceBack(L);
    if (L.tagName === 'DIALOG') { // exactly what Esc does
      const ev = new Event('cancel', { cancelable: true });
      L.dispatchEvent(ev);
      if (!ev.defaultPrevented && L.open) L.close();
      if (L.id === 'regDlg' && L.open) return false; // the sign-up screen stays; a second press leaves the app
      return true;
    }
    const fixed = CLOSE_ID[L.id] && $(CLOSE_ID[L.id]);
    if (fixed) { fixed.click(); return true; }
    const b = bestButton(L);
    if (b) { b.click(); return true; }
    pressEsc(L);
    setTimeout(() => { // a small menu that ignored Esc is just put away
      if (!shown(L) || !L.matches(LIGHT)) return;
      L.hidden = true;
      if (shown(L)) L.classList.add('hidden');
    }, 80);
    return true;
  }

  /* ---------- one step back ---------- */
  function stepBack() {
    const busy = $('busy');
    if (busy && !busy.classList.contains('hidden') && shown(busy)) { say('רגע, פעולה עדיין רצה'); return true; }

    const L = topLayer();
    if (L && closeLayer(L) !== false) return true;

    const ra = document.querySelector('.ra:not(.hidden)');
    if (ra && shown(ra)) { const s = ra.querySelector('[data-a="stop"]'); if (s) { s.click(); return true; } }

    const T = window.SIMAN_TABS, cur = T && T.TB && T.TB.cur;
    const hasS = typeof S !== 'undefined' && S;
    if (hasS && S.doc && !(cur && cur.ed)) {
      if (S.picked && typeof pickAnn === 'function') { pickAnn(null); return true; }
      if (S.tool && S.tool !== 'select' && typeof setTool === 'function') { setTool('select'); return true; }
    }
    if (cur && typeof T.closeTab === 'function') { T.closeTab(cur); return true; }
    return false;
  }
})();
