"use strict";

(function () {
    VcfCheckUI.currentReport = null;
    VcfCheckUI.currentNormalizedResults = [];
    VcfCheckUI.environments = [];
    VcfCheckUI.editingEnvironmentId = null;
    VcfCheckUI.checksByArea = {};
    VcfCheckUI.rootCredentialCheckIds = [];
    VcfCheckUI.collapsedCheckAreas = {}; // area name -> true, for advanced check picker categories collapsed by the user (default open)
    VcfCheckUI.pollTimer = null;
    VcfCheckUI.isRunning = false;
    VcfCheckUI.logOffset = 0;
    VcfCheckUI.lastQueue = [];
    // Internal namespace for the sizing wizard's own state and helpers, shared across
    // sizing-wizard-core.js/-steps.js/-detect.js. Everything under it is private to those
    // three files - the wizard's only public entry point is VcfCheckUI.renderSizingEnvironmentSelect.
    VcfCheckUI._sizing = {};

})();
