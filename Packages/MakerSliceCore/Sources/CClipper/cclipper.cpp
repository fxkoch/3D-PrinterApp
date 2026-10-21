#include "cclipper.h"
#include "clipper2/clipper2/clipper.h"

#include <cstdlib>
#include <cstring>

using namespace Clipper2Lib;

namespace {

Paths64 toPaths(const int64_t *xy, const size_t *counts, size_t pathCount) {
    Paths64 result;
    result.reserve(pathCount);
    size_t offset = 0;
    for (size_t p = 0; p < pathCount; ++p) {
        Path64 path;
        path.reserve(counts[p]);
        for (size_t i = 0; i < counts[p]; ++i) {
            path.emplace_back(xy[offset * 2], xy[offset * 2 + 1]);
            ++offset;
        }
        result.push_back(std::move(path));
    }
    return result;
}

cc_paths *fromPaths(const Paths64 &paths) {
    cc_paths *out = static_cast<cc_paths *>(std::calloc(1, sizeof(cc_paths)));
    size_t total = 0;
    for (const auto &p : paths) total += p.size();
    out->path_count = paths.size();
    out->counts = static_cast<size_t *>(std::malloc(sizeof(size_t) * (paths.size() + 1)));
    out->xy = static_cast<int64_t *>(std::malloc(sizeof(int64_t) * (total * 2 + 1)));
    size_t offset = 0;
    for (size_t i = 0; i < paths.size(); ++i) {
        out->counts[i] = paths[i].size();
        for (const auto &pt : paths[i]) {
            out->xy[offset * 2] = pt.x;
            out->xy[offset * 2 + 1] = pt.y;
            ++offset;
        }
    }
    return out;
}

FillRule fillRule(int rule) {
    switch (rule) {
        case CC_FILL_NONZERO: return FillRule::NonZero;
        case CC_FILL_POSITIVE: return FillRule::Positive;
        default: return FillRule::EvenOdd;
    }
}

}  // namespace

extern "C" {

cc_paths *cc_offset(const int64_t *xy, const size_t *counts, size_t path_count,
                    double delta, int join_type, double miter_limit) {
    JoinType jt = join_type == CC_JOIN_ROUND ? JoinType::Round
                : join_type == CC_JOIN_MITER ? JoinType::Miter
                : JoinType::Square;
    Paths64 result = InflatePaths(toPaths(xy, counts, path_count), delta, jt,
                                  EndType::Polygon, miter_limit);
    return fromPaths(result);
}

cc_paths *cc_boolean(int op, int fill_rule,
                     const int64_t *subj_xy, const size_t *subj_counts, size_t subj_count,
                     const int64_t *clip_xy, const size_t *clip_counts, size_t clip_count) {
    ClipType ct = op == CC_OP_UNION ? ClipType::Union
                : op == CC_OP_DIFFERENCE ? ClipType::Difference
                : op == CC_OP_XOR ? ClipType::Xor
                : ClipType::Intersection;
    Clipper64 clipper;
    clipper.AddSubject(toPaths(subj_xy, subj_counts, subj_count));
    if (clip_count > 0) clipper.AddClip(toPaths(clip_xy, clip_counts, clip_count));
    Paths64 result;
    clipper.Execute(ct, fillRule(fill_rule), result);
    return fromPaths(result);
}

cc_paths *cc_clip_lines(const int64_t *line_xy, const size_t *line_counts, size_t line_count,
                        const int64_t *clip_xy, const size_t *clip_counts, size_t clip_count) {
    Clipper64 clipper;
    clipper.AddOpenSubject(toPaths(line_xy, line_counts, line_count));
    clipper.AddClip(toPaths(clip_xy, clip_counts, clip_count));
    Paths64 closed, open;
    clipper.Execute(ClipType::Intersection, FillRule::EvenOdd, closed, open);
    return fromPaths(open);
}

cc_paths *cc_simplify(const int64_t *xy, const size_t *counts, size_t path_count, double epsilon) {
    return fromPaths(SimplifyPaths(toPaths(xy, counts, path_count), epsilon, true));
}

cc_paths *cc_triangulate(const int64_t *xy, const size_t *counts, size_t path_count) {
    Paths64 solution;
    if (Triangulate(toPaths(xy, counts, path_count), solution, true) != TriangulateResult::success) return nullptr;
    return fromPaths(solution);
}

double cc_area(const int64_t *xy, size_t count) {
    Path64 path;
    path.reserve(count);
    for (size_t i = 0; i < count; ++i) path.emplace_back(xy[i * 2], xy[i * 2 + 1]);
    return Area(path);
}

void cc_free(cc_paths *paths) {
    if (!paths) return;
    std::free(paths->xy);
    std::free(paths->counts);
    std::free(paths);
}

}  // extern "C"
