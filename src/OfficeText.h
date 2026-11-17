#ifndef OFFICE_TEXT_H
#define OFFICE_TEXT_H

#include <stddef.h>

// Plain-C text extraction for Word (.docx) and PowerPoint (.pptx) files.
// Both formats are ZIP archives of XML; Gemini cannot read them directly, so the app pulls the text out locally.
//
// Return a malloc'd, NUL-terminated UTF-8 string (caller frees), or NULL on failure with *err set:
enum {
    OFFICE_OK = 0,
    OFFICE_ERR_NOT_ZIP = 1,       // not a ZIP / corrupt archive
    OFFICE_ERR_MISSING_PART = 2,  // the archive does not contain the expected document part
    OFFICE_ERR_UNSUPPORTED = 3,   // encrypted, ZIP64, or an unsupported compression method
    OFFICE_ERR_TOO_LARGE = 4,     // would expand past the safety limit
    OFFICE_ERR_NO_MEMORY = 5
};

char *office_docx_text(const unsigned char *zip, size_t zipLen, int *err);
char *office_pptx_text(const unsigned char *zip, size_t zipLen, int *err);
char *office_zip_text(const unsigned char *zip, size_t zipLen, int *err);

#endif
