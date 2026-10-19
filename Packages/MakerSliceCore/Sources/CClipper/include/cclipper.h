// Minimal C interface to Clipper2 so Swift can call it without C++ interop.
// All coordinates are integer micrometres. Paths are passed as a flat array
// of x,y pairs plus a per-path point count.
#ifndef CCLIPPER_H
#define CCLIPPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int64_t *xy;        // 2 * total point count
    size_t *counts;     // points per path
    size_t path_count;
} cc_paths;

enum { CC_JOIN_SQUARE = 0, CC_JOIN_ROUND = 1, CC_JOIN_MITER = 2 };
enum { CC_OP_INTERSECTION = 1, CC_OP_UNION = 2, CC_OP_DIFFERENCE = 3, CC_OP_XOR = 4 };
enum { CC_FILL_EVENODD = 0, CC_FILL_NONZERO = 1, CC_FILL_POSITIVE = 2 };

/// Offsets closed polygons by `delta` (negative shrinks).
cc_paths *cc_offset(const int64_t *xy, const size_t *counts, size_t path_count,
                    double delta, int join_type, double miter_limit);

/// Boolean operation between two sets of closed polygons.
cc_paths *cc_boolean(int op, int fill_rule,
                     const int64_t *subj_xy, const size_t *subj_counts, size_t subj_count,
                     const int64_t *clip_xy, const size_t *clip_counts, size_t clip_count);

/// Clips open polylines against closed polygons, returning the inside pieces.
cc_paths *cc_clip_lines(const int64_t *line_xy, const size_t *line_counts, size_t line_count,
                        const int64_t *clip_xy, const size_t *clip_counts, size_t clip_count);

/// Removes vertices closer than `epsilon` to the simplified outline.
cc_paths *cc_simplify(const int64_t *xy, const size_t *counts, size_t path_count, double epsilon);

/// Signed area of a single closed path (positive = counter-clockwise).
double cc_area(const int64_t *xy, size_t count);

void cc_free(cc_paths *paths);

#ifdef __cplusplus
}
#endif

#endif
