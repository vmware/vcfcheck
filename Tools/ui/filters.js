"use strict";

(function () {
    // TEST-EXTRACT-FILTERS-START (see Tests/vcf-check-ui.filters.test.js - keep this marker
    // pair around the filter-tile/isResultVisible block so the test can eval it verbatim)
    VcfCheckUI.STATUS_ORDER = { Fail: 0, Warning: 1, Error: 2, Skipped: 3, Pass: 4 };
    VcfCheckUI.AREA_ORDER = { "Aria Suite": 0, "ESX": 1, "NSX": 2, "SDDC Manager": 3, "vCenter": 4, "vSAN": 5 };
    VcfCheckUI.CSV_COLUMNS = [
        "CheckId", "Area", "Domain", "Component", "DisplayName", "Status", "Blocking", "Informational", "TargetComponent",
        "Destination", "Information", "Detail", "SkipReasonTag", "ValidationCriteria", "Remediation", "StartedAt", "CompletedAt", "DurationMs", "Exception"
    ];
    VcfCheckUI.EXPORT_BUTTON_IDS = ["export-html-button", "export-pdf-button", "export-zip-button"];

    // Filter tiles: [summaryKey, label, isBlockingTile, predicate]. A result is visible if it
    // matches at least one active filter - "blockingFailures" and "fail" are independent
    // toggles even though a blocking Fail matches both, so turning one off alone doesn't hide it.
    VcfCheckUI.STATUS_FILTER_TILES = [
        ["blockingFailures", "Blocking Failures", true, function (r) { return r.status === "Fail" && !!r.blocking; }],
        ["fail", "Fail", false, function (r) { return r.status === "Fail"; }],
        ["warning", "Warning", false, function (r) { return r.status === "Warning"; }],
        ["error", "Error", false, function (r) { return r.status === "Error"; }],
        ["skipped", "Skipped", false, function (r) { return r.status === "Skipped"; }],
        ["pass", "Pass", false, function (r) { return r.status === "Pass"; }]
    ];
    VcfCheckUI.statusFilters = {};
    VcfCheckUI.STATUS_FILTER_TILES.forEach(function (tile) { VcfCheckUI.statusFilters[tile[0]] = true; });

    // Component (area) filter tiles: [areaKey, label, predicate]. Independent of the status
    // filter row above - a result must match at least one active status filter AND at least
    // one active area filter to be visible.
    VcfCheckUI.AREA_FILTER_TILES = Object.keys(VcfCheckUI.AREA_ORDER).sort(function (a, b) { return VcfCheckUI.AREA_ORDER[a] - VcfCheckUI.AREA_ORDER[b]; })
        .map(function (area) {
            return [area, area, function (r) { return r.area === area; }];
        });
    VcfCheckUI.areaFilters = {};
    VcfCheckUI.AREA_FILTER_TILES.forEach(function (tile) { VcfCheckUI.areaFilters[tile[0]] = true; });

    VcfCheckUI.isResultVisible = function (result) {
        var statusMatch = VcfCheckUI.STATUS_FILTER_TILES.some(function (tile) {
            return VcfCheckUI.statusFilters[tile[0]] && tile[3](result);
        });
        var areaMatch = VcfCheckUI.AREA_FILTER_TILES.some(function (tile) {
            return VcfCheckUI.areaFilters[tile[0]] && tile[2](result);
        });
        return statusMatch && areaMatch;
    }
    // TEST-EXTRACT-FILTERS-END

})();
