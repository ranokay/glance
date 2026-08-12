#ifndef GLANCE_PREVIEW_CORE_H
#define GLANCE_PREVIEW_CORE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct GlanceRenderResult {
	uint8_t *data;
	size_t length;
	int32_t status;
} GlanceRenderResult;

enum {
	GLANCE_STATUS_OK = 0,
	GLANCE_STATUS_INVALID_INPUT = 1,
	GLANCE_STATUS_PARSE_ERROR = 2,
	GLANCE_STATUS_INTERNAL_ERROR = 3,
	GLANCE_STATUS_IO_ERROR = 4,
	GLANCE_STATUS_RESOURCE_LIMIT = 5,
	GLANCE_STATUS_UNSUPPORTED = 6,
};

/*
 * Successful results contain payload bytes. Nonzero statuses contain a UTF-8 error message.
 * The caller owns every non-NULL data buffer and must release it exactly once with
 * glance_render_buffer_free, passing the returned length unchanged.
 */

GlanceRenderResult glance_render_code(
	const uint8_t *source_data,
	size_t source_length,
	const uint8_t *lexer_data,
	size_t lexer_length
);
GlanceRenderResult glance_render_markdown(const uint8_t *source_data, size_t source_length);
GlanceRenderResult glance_render_notebook(const uint8_t *source_data, size_t source_length);
GlanceRenderResult glance_parse_tsv(const uint8_t *data, size_t data_length);
GlanceRenderResult glance_scan_zip(const uint8_t *path_data, size_t path_length);
GlanceRenderResult glance_scan_tar(
	const uint8_t *path_data,
	size_t path_length,
	bool is_gzipped
);
GlanceRenderResult glance_scan_seven_zip(const uint8_t *path_data, size_t path_length);
void glance_render_buffer_free(uint8_t *data, size_t length);

#endif
