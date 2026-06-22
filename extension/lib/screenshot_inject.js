// Render the visible page to a PNG data URL using html2canvas.
// Loaded together with html2canvas.min.js via chrome.scripting.executeScript.
//
// Returns a Promise that resolves to { data_url, width, height, method } —
// chrome.scripting awaits the Promise and surfaces the resolved value.
(async () => {
  if (typeof html2canvas !== "function") {
    return { ok: false, error: "html2canvas not loaded" };
  }
  try {
    // Cap the rendered area at the visible viewport to keep size sane and fast.
    const w = window.innerWidth || document.documentElement.clientWidth || 1280;
    const h = window.innerHeight || document.documentElement.clientHeight || 800;
    const canvas = await html2canvas(document.body, {
      width: w,
      height: h,
      x: window.scrollX || 0,
      y: window.scrollY || 0,
      windowWidth: w,
      windowHeight: h,
      logging: false,
      useCORS: true,
      allowTaint: true,
      // Lower scale for faster render on retina; PNG ends up ~viewport size.
      scale: 1,
      backgroundColor: null,
    });
    return {
      ok: true,
      data_url: canvas.toDataURL("image/png"),
      width: canvas.width,
      height: canvas.height,
      method: "html2canvas",
    };
  } catch (e) {
    return { ok: false, error: String(e && e.message || e) };
  }
})();
