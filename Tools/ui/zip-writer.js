"use strict";

(function () {
    // ---- Minimal in-browser ZIP writer (STORE method, no compression) ----
    // No external dependency (this tool stays fully self-contained/offline) - only the small
    // subset of the ZIP format exportZip() actually needs: a local file header + data per file,
    // a central directory record per file, and one end-of-central-directory record.

    var CRC32_TABLE = buildCrc32Table();

    function buildCrc32Table() {
        var table = [];
        for (var i = 0; i < 256; i++) {
            var c = i;
            for (var bit = 0; bit < 8; bit++) {
                c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
            }
            table[i] = c >>> 0;
        }
        return table;
    }

    function crc32(bytes) {
        var crc = 0xFFFFFFFF;
        for (var i = 0; i < bytes.length; i++) {
            crc = CRC32_TABLE[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
        }
        return (crc ^ 0xFFFFFFFF) >>> 0;
    }

    function writeUint32LE(bytes, offset, value) {
        bytes[offset] = value & 0xFF;
        bytes[offset + 1] = (value >>> 8) & 0xFF;
        bytes[offset + 2] = (value >>> 16) & 0xFF;
        bytes[offset + 3] = (value >>> 24) & 0xFF;
    }

    function writeUint16LE(bytes, offset, value) {
        bytes[offset] = value & 0xFF;
        bytes[offset + 1] = (value >>> 8) & 0xFF;
    }

    VcfCheckUI.buildZipBlob = function (files) {
        var encoder = new TextEncoder();
        var encodedFiles = files.map(function (file) {
            var dataBytes = file.content instanceof Uint8Array ? file.content : encoder.encode(file.content);
            return { nameBytes: encoder.encode(file.name), dataBytes: dataBytes, crc: crc32(dataBytes) };
        });

        var localParts = [];
        var centralParts = [];
        var offset = 0;

        encodedFiles.forEach(function (file) {
            var header = new Uint8Array(30);
            writeUint32LE(header, 0, 0x04034b50);
            writeUint16LE(header, 4, 20);      // version needed to extract
            writeUint16LE(header, 6, 0x0800);  // general purpose flag: UTF-8 filename
            writeUint16LE(header, 8, 0);       // compression method: stored
            writeUint16LE(header, 10, 0);      // last mod file time
            writeUint16LE(header, 12, 0);      // last mod file date
            writeUint32LE(header, 14, file.crc);
            writeUint32LE(header, 18, file.dataBytes.length);
            writeUint32LE(header, 22, file.dataBytes.length);
            writeUint16LE(header, 26, file.nameBytes.length);
            writeUint16LE(header, 28, 0);      // extra field length
            localParts.push(header, file.nameBytes, file.dataBytes);

            var central = new Uint8Array(46);
            writeUint32LE(central, 0, 0x02014b50);
            writeUint16LE(central, 4, 20);      // version made by
            writeUint16LE(central, 6, 20);      // version needed to extract
            writeUint16LE(central, 8, 0x0800);  // general purpose flag: UTF-8 filename
            writeUint16LE(central, 10, 0);      // compression method: stored
            writeUint16LE(central, 12, 0);      // last mod file time
            writeUint16LE(central, 14, 0);      // last mod file date
            writeUint32LE(central, 16, file.crc);
            writeUint32LE(central, 20, file.dataBytes.length);
            writeUint32LE(central, 24, file.dataBytes.length);
            writeUint16LE(central, 28, file.nameBytes.length);
            writeUint16LE(central, 30, 0);      // extra field length
            writeUint16LE(central, 32, 0);      // file comment length
            writeUint16LE(central, 34, 0);      // disk number start
            writeUint16LE(central, 36, 0);      // internal file attributes
            writeUint32LE(central, 38, 0);      // external file attributes
            writeUint32LE(central, 42, offset); // relative offset of local header
            centralParts.push(central, file.nameBytes);

            offset += header.length + file.nameBytes.length + file.dataBytes.length;
        });

        var centralDirectoryOffset = offset;
        var centralDirectorySize = 0;
        centralParts.forEach(function (part) { centralDirectorySize += part.length; });

        var endRecord = new Uint8Array(22);
        writeUint32LE(endRecord, 0, 0x06054b50);
        writeUint16LE(endRecord, 4, 0);
        writeUint16LE(endRecord, 6, 0);
        writeUint16LE(endRecord, 8, encodedFiles.length);
        writeUint16LE(endRecord, 10, encodedFiles.length);
        writeUint32LE(endRecord, 12, centralDirectorySize);
        writeUint32LE(endRecord, 16, centralDirectoryOffset);
        writeUint16LE(endRecord, 20, 0);

        return new Blob(localParts.concat(centralParts).concat([endRecord]), { type: "application/zip" });
    }

    VcfCheckUI.formatTimestampForFilename = function () {
        var now = new Date();
        var pad = function (value) { return String(value).padStart(2, "0"); };
        return now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()) + "-" +
            pad(now.getHours()) + "-" + pad(now.getMinutes()) + "-" + pad(now.getSeconds());
    }

    VcfCheckUI.downloadBlob = function (content, mimeType, filename) {
        var blob = new Blob([content], { type: mimeType });
        var url = URL.createObjectURL(blob);
        var link = document.createElement("a");
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }


})();
