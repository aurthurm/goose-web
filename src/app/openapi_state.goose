import src.constants.limits;
namespace web;

// Describe-pass state held by Ctx. Goose refuses to shrink a Ctx field while the routes
// block (which captures c) is live, so every change to these structs is made on a local
// copy and written back as a whole value. The growable buffer is the final field.
const OAS_MAX_TITLE_BYTES = 128;
const OAS_MAX_VERSION_BYTES = 32;
const OAS_MAX_DESCRIPTION_BYTES = 512;
const OAS_MAX_PATH_BYTES = 128;
const OAS_MAX_TEXT_BYTES = 128;
const OAS_MAX_TAG_BYTES = 64;
// Schema, response and parameter fragments for one operation. Annotations past these
// capacities abort in the describe pass (/openapi.json), which is a programmer error.
const OAS_MAX_FRAGMENT_BYTES = 4096;

// Document settings, set by openapi() for each request.
struct OasConfig {
    enabled: bool,
    title: u8[..OAS_MAX_TITLE_BYTES],
    version: u8[..OAS_MAX_VERSION_BYTES],
    description: u8[..OAS_MAX_DESCRIPTION_BYTES],
    json_path: u8[..OAS_MAX_PATH_BYTES],
    docs_path: u8[..OAS_MAX_PATH_BYTES],
}

// Annotations waiting for the next route.
struct OasPending {
    summary: u8[..OAS_MAX_TEXT_BYTES],
    tag: u8[..OAS_MAX_TAG_BYTES],
    request: u8[..OAS_MAX_FRAGMENT_BYTES],
    responses: u8[..OAS_MAX_FRAGMENT_BYTES],
    params: u8[..OAS_MAX_FRAGMENT_BYTES],
}

// One finished operation. Its path and JSON object live in OpenApiState.text.
struct OpEntry { verb: u8[..8], path_start: i64, path_len: i64, op_start: i64, op_len: i64 }

struct OpenApiState {
    config: OasConfig,
    pending: OasPending,
    ops: OpEntry[MAX_ROUTES],
    op_count: i64,
    // Growable buffer is the final field: Goose requires that for resizable fields.
    text: u8[>..],
}
