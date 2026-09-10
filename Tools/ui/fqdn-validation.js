"use strict";

(function () {
    // ---- FQDN/IP input validation (alphanumeric, period, hyphen, colon only) ----

    function validateFqdnInput(event) {
        var input = event.target;
        var validChars = /[^a-zA-Z0-9.\-:]/g;
        if (validChars.test(input.value)) {
            input.value = input.value.replace(validChars, '');
        }
    }
    document.getElementById("env-form-fqdn").addEventListener("input", validateFqdnInput);

    VcfCheckUI.validateFqdnInput = validateFqdnInput;

})();
