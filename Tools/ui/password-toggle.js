"use strict";

(function () {
    // ---- Password show/hide (attached per-field at creation time, since environment/run-scan
    // password inputs are all created dynamically rather than existing statically in the DOM) ----

    VcfCheckUI._INFO_ICON = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="11" x2="12" y2="16"/><circle cx="12" cy="7.5" r="1.3" fill="currentColor" stroke="none"/></svg>';
    var _EYE_SHOW ='<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
    var _EYE_HIDE = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';

    function togglePasswordVisibility(button) {
        var input = button.previousElementSibling;
        if (!input || input.tagName !== "INPUT") return;
        var revealing = input.type === "password";
        input.type = revealing ? "text" : "password";
        VcfCheckUI.setInlineSvg(button, revealing ? _EYE_HIDE : _EYE_SHOW);
        button.setAttribute("aria-pressed", String(revealing));
        button.title = revealing ? "Hide password" : "Show password";
    }

    VcfCheckUI.buildPasswordField = function (inputId, labelText) {
        var field = VcfCheckUI.el("div", "field");
        field.style.minWidth = Math.max(200, labelText.length * 7.5) + "px";
        var label = VcfCheckUI.el("label", null, labelText);
        label.setAttribute("for", inputId);
        field.appendChild(label);
        var wrap = VcfCheckUI.el("div", "pw-wrap");
        var input = document.createElement("input");
        input.type = "password";
        input.id = inputId;
        input.autocomplete = "off";
        var eyeButton = document.createElement("button");
        eyeButton.type = "button";
        eyeButton.className = "pw-eye";
        VcfCheckUI.setInlineSvg(eyeButton, _EYE_SHOW);
        eyeButton.title = "Show password";
        eyeButton.setAttribute("aria-pressed", "false");
        eyeButton.addEventListener("click", function () { togglePasswordVisibility(eyeButton); });
        wrap.appendChild(input);
        wrap.appendChild(eyeButton);
        field.appendChild(wrap);
        return field;
    }


})();
