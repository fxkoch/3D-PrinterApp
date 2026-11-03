// Gravity self-clamping wall holder (electric toothbrush / shaver)
// --------------------------------------------------------------
// How it works: the device stands in the foot ring of the slider.
// Its weight pulls the slider down; the slider pulls the inner lever
// ends of both arms down, so the arms rotate and the two grip pads
// swing inward against the device. Lift the device out and the pads
// open again (pushing the pads apart lifts the slider).
//
// Coordinates: x = right, y = away from the wall, z = up.
// No screws: arms and slider sit on pins printed onto the back plate and are
// held by printed snap clips (like E-clips) that click sideways into a groove
// on each pin. The clips are printed flat, so they flex within the layers. Mount the back
// plate with double-sided foam tape (or the optional screw holes).
//
// Render a single part with:  openscad -D 'part="arm_right"' -o x.stl this.scad

/* [Device] */
// preset: measured devices, or "custom" to use the values below
preset  = "custom"; // [custom, mijia, oneblade]
c_dev_w  = 30;  // custom: width of the device at grip height (mm)
c_dev_d  = 30;  // custom: depth of the device (front to back, mm)
c_foot_w = 32;  // custom: inner width of the foot pocket (device bottom + ~2 mm)
c_foot_d = 32;  // custom: inner depth of the foot pocket
c_foot_r = 16;  // custom: corner radius of the foot pocket (= half width -> round)
c_dev_r  = 15;  // custom: corner radius of the device cross-section (for the front claws)

// measured: Xiaomi Mijia toothbrush, bottom 28.4 x 29.2 mm, round
// measured: Philips OneBlade Pro 360 (QP6541), bottom 34.7 x 33.2 mm, rounded square
P = preset == "mijia"    ? [28.4, 29.2, 30.6, 31.4, 15.3, 14.2]
  : preset == "oneblade" ? [34.7, 33.2, 36.8, 35.3, 9, 8]
  : [c_dev_w, c_dev_d, c_foot_w, c_foot_d, c_foot_r, c_dev_r];
dev_w  = P[0];
dev_d  = P[1];
foot_w = P[2];
foot_d = P[3];
foot_r = min(P[4], foot_w/2, foot_d/2);
dev_r  = min(P[5], dev_w/2, dev_d/2);

/* [Mechanism] */
lever   = 12;   // distance pivot -> lever pin
pad_h   = 30;   // grip pad height
travel_up   = 4;   // slider travel above neutral (opens pads)
travel_down = 3;   // slider travel below neutral (closes pads)
lip     = 7;    // front claw: how far it reaches around the front of the device
lip_clr = 0.6;  // clearance between claw and device

/* [Brush head caddy] */
// Spare brush heads stand on pegs in a small shelf clipped to a wing of the back plate.
// -1 = automatic (2 for the Mijia toothbrush, none otherwise), 0 = no caddy.
head_slots  = -1;
head_base_d = 18.43; // widest diameter of the brush head's foot (measured)
head_hole_d = 4.88;  // hole in the brush head for the drive pin (measured)

/* [Self-opening counterweight] */
// Each arm carries a round counterweight outboard of its pivot. Without a
// device the counterweights tip the pads open (and push the slider up);
// the device's weight on the foot overrides them and closes the pads.
// Lift the device and the holder opens by itself.
nut_af  = 13;   // hex nut across flats (M8 = 13)
nut_h   = 6.5;  // hex nut height (M8 = 6.5)
nuts    = 2;    // nuts per arm (pocket depth)
cw_x    = 15;   // counterweight centre: distance outboard of the pivot

/* [Plates] */
bt   = 4;     // back plate thickness
at   = 4;     // arm thickness
st   = 4;     // slider thickness
gap  = 0.5;   // gap between arm layer and slider layer
clr  = 0.35;  // radial clearance for pins / bosses
wall_screws = false; // add 2 countersunk holes for wall screws
edge = 1.2;   // chamfer on visible front edges (modern look)

/* [View] */
part = "assembly"; // [assembly, backplate, arm_right, arm_left, slider, clip_pivot, clip_guide, caddy, print_plate]
s    = 0;          // slider position for assembly view (+ = down / closed)
show_device = true;

$fn = 64;

// ---------------- derived values ----------------
R   = dev_w/2;
pz  = 30;                 // pivot height above foot floor (neutral)
px  = R + 3;              // pivot x
lx  = px - lever;         // lever pin x (neutral)
H   = 8 + pad_h;          // upright height above pivot
S0  = bt + at + gap;      // slider back face
S1  = S0 + st;            // slider front face
clip_t = 1.6;             // snap clip thickness
groove = clip_t + 0.2;    // groove length on the pins
pin_tip = 1.2;            // pin length beyond the groove
cap_h = groove + pin_tip; // how far a pin sticks out in front of the part it holds
yb  = S1 + 0.3 + cap_h + 0.7; // back of device (clears the guide pins and clips)
cy  = yb + dev_d/2;       // device centre (y)
Fw  = foot_w/2; Fd = foot_d/2;
pad_front = cy + dev_d/2;  // pads + claws reach around the front of the device
pin_d = 5;
boss_d = 6;               // arm pivot pin
groove_d  = 4.4;          // pivot pin diameter in the clip groove
gx  = 7; gz = 16;         // slider guide bosses (±gx, gz)
gboss_d = 5;              // guide pin diameter
gshoulder_d = 9;
ggroove_d = 3.6;          // guide pin diameter in the clip groove
cw_r = (nut_af + 0.4)/sqrt(3) + 1.8;   // counterweight boss radius
cw_len = nuts*(nut_h + 0.1) + 1.2;      // counterweight boss length (y)
bp_w = 2*(px + cw_x + cw_r + 2);        // back plate width
bp_z0 = -3 - travel_down - 1;
// brush head caddy
heads   = head_slots >= 0 ? head_slots : (preset == "mijia" ? 2 : 0);
hs      = head_base_d + 4;            // spacing of the heads
hr      = head_base_d/2 + 0.6;        // ring inner radius
cad_x0  = bp_w/2 + 2;                 // caddy starts right of the main plate
cad_w   = heads * hs + 8;
cad_z1  = 30;                         // top of the caddy back plate
cad_yc  = bt + at + hr + 0.4;         // head axis (y)
cad_pins = [[cad_x0 + 6, 22], [cad_x0 + cad_w - 6, 22]];
bp_xr   = heads > 0 ? cad_x0 + cad_w : bp_w/2; // right edge of the back plate
bp_z1 = pz + H + 2;
phi_max = asin(travel_down/lever);
phi_min = -asin(travel_up/lever);

echo(str("pad gap closed = ", 2*(R - (3*(1-cos(phi_max)) + 8*sin(phi_max))), " .. open(top) = ",
         2*(R + H*sin(-phi_min))));

// ---------------- helpers ----------------
module rrect(x0, x1, z0, z1, r=3) {
    hull() for (x=[x0+r, x1-r], z=[z0+r, z1-r]) translate([x, z]) circle(r);
}
// extrude a 2D shape drawn in the x-z plane between y0 and y1
module xz(y0, y1) {
    translate([0, y1, 0]) rotate([90, 0, 0]) linear_extrude(y1 - y0) children();
}
// same, but the front face (y1) gets a stepped chamfer of size c
module xzc(y0, y1, c=edge, n=6) {
    xz(y0, y1 - c) children();
    for (i=[0:n-1]) xz(y1 - c + i*c/n, y1 - c + (i+1)*c/n)
        offset(delta=-(i+1)*c/n) children();
}

// ---------------- snap pins and clips ----------------
// Pin along +z: full diameter up to z0, groove for the clip, short chamfered tip.
module snap_pin(d, gd, z0) {
    cylinder(d=d, h=z0);
    translate([0, 0, z0 - 0.01]) cylinder(d=gd, h=groove + 0.02);
    translate([0, 0, z0 + groove]) hull() {
        cylinder(d=d, h=pin_tip - 0.5);
        cylinder(d=d - 1, h=pin_tip);
    }
}
// Snap clip for a groove of diameter gd: a domed ring with an opening narrower than the groove,
// so it clicks on sideways. Opening points along +x.
module snap_clip(gd, od=10) {
    open = gd * 0.8;
    difference() {
        hull() { cylinder(d=od, h=clip_t - 0.5); cylinder(d=od - 1, h=clip_t); }
        translate([0, 0, -1]) cylinder(d=gd + 0.2, h=clip_t + 2);
        translate([0, -open/2, -1]) cube([od, open, clip_t + 2]);
        // lead-in: the mouth widens towards the outside
        translate([0, 0, -1]) linear_extrude(clip_t + 2)
            polygon([[gd/2 + 0.4, -open/2], [od/2 + 0.5, -open/2 - 1.4], [od/2 + 0.5, open/2 + 1.4], [gd/2 + 0.4, open/2]]);
    }
}

// ---------------- back plate ----------------
module backplate() {
    difference() {
        union() {
            xzc(0, bt, 1.5) hull() {
                rrect(-bp_w/2, bp_w/2, bp_z0, bp_z1, 10);
                if (heads > 0) rrect(bp_w/2 - 20, bp_xr, bp_z0, cad_z1 + 4, 8);  // wing for the caddy
            }
            // pins for the brush head caddy (same snap pins and clips as the arms)
            if (heads > 0) for (pp = cad_pins) translate([pp[0], 0, pp[1]]) rotate([-90,0,0])
                snap_pin(boss_d, groove_d, bt + at + 0.3);
            // arm pivot pins
            for (m=[0,1]) mirror([m,0,0]) translate([px, 0, pz]) rotate([-90,0,0])
                snap_pin(boss_d, groove_d, bt + at + 0.3);
            // slider guide pins: shoulder through the arm layer, pin through the slider
            for (m=[0,1]) mirror([m,0,0]) translate([gx, 0, gz]) rotate([-90,0,0]) {
                cylinder(d=gshoulder_d, h=S0);
                snap_pin(gboss_d, ggroove_d, S1 + 0.3);
            }
        }
        if (wall_screws) for (z=[bp_z1-8, bp_z0+6]) translate([0, -0.01, z]) rotate([-90,0,0]) {
            cylinder(d=4, h=bt+1, $fn=24);
            translate([0,0,bt-2]) cylinder(d1=4, d2=8.5, h=2.02, $fn=32);
        }
    }
}

// ---------------- arm (right; left is mirrored) ----------------
// local frame: pivot at origin, drawn at phi = 0 (pads vertical, touching dev_w)
module arm_local() {
    difference() {
        union() {
            xzc(bt, bt + at) {
                hull() { circle(r=6.5); translate([-lever, 0]) circle(r=4); }     // lever
                hull() { circle(r=6.5); translate([0, H - 3]) circle(r=3); }    // upright, rounded top
                hull() { circle(r=6.5); translate([cw_x, 0]) circle(r=cw_r); } // counterweight arm
            }
            // counterweight boss (pocket for hex nuts, open to the front)
            translate([cw_x, bt, 0]) rotate([-90,0,0]) hull() {
                cylinder(r=cw_r, h=cw_len - 1);
                cylinder(r=cw_r - 1, h=cw_len);
            }
            // front claw: wraps around the front of the device so it cannot fall forward
            difference() {
                intersection() {
                    xz(cy - 2, pad_front) polygon([[-3 + 0.01, 8], [-3 - lip, 8 + lip],
                                                  [-3 - lip, 8 + pad_h - lip - 2], [-3 + 0.01, 8 + pad_h - 2]]);
                    pad_profile(-3 - lip - 1, 0, 0);
                }
                translate([-px, cy, -50]) linear_extrude(200) dev2d(lip_clr);
            }
            // pin into the slider
            translate([-lever, bt + at - 0.01, 0]) rotate([-90,0,0])
                cylinder(d=pin_d, h=gap + st + 0.01);
            // grip pad: vertical fin facing the device
            difference() {
                // soft rounded fin with chamfered edges: big radius at the front corners
                pad_profile(-3, 0, 0.8);
                // lead-in chamfer at the top inner edge
                translate([-3, bt - 1, 8 + pad_h]) rotate([0, 45, 0]) cube([3, 60, 3], center=false);
            }
        }
        translate([0, bt - 1, 0]) rotate([-90,0,0]) cylinder(d=boss_d + 2*clr, h=at + 2); // pivot hole
        // nut pocket
        translate([cw_x, bt + 1.2, 0]) rotate([-90,0,0])
            cylinder(d=(nut_af + 0.4)*2/sqrt(3), h=cw_len, $fn=6);
    }
}
// side profile of the grip pad (y-z), extruded along x from x0 to x1, edges chamfered by c
module pad_profile(x0, x1, c) {
    hull() for (k=[[bt + 1, 8 + 1, 1], [bt + 1, 8 + pad_h - 1, 1],
                   [pad_front - 8, 8 + 8, 8], [pad_front - 8, 8 + pad_h - 8, 8]])
        translate([x0, k[0], k[1]]) rotate([0,90,0]) {
            translate([0,0,c]) cylinder(r=k[2], h=x1 - x0 - 2*c);
            cylinder(r=k[2] - c, h=x1 - x0);
        }
}
// cross-section of the device (rounded rectangle), grown by o
module dev2d(o=0) {
    offset(r=o) hull() for (mx=[-1,1], my=[-1,1])
        translate([mx*(dev_w/2 - dev_r), my*(dev_d/2 - dev_r)]) circle(r=dev_r);
}
// hex nuts in their pockets (for the assembly view)
module nuts_in_arm() for (i=[0:nuts-1])
    translate([cw_x, bt + 1.2 + i*(nut_h + 0.1), 0]) rotate([-90,0,0]) cylinder(d=nut_af*2/sqrt(3), h=nut_h, $fn=6);
module arm_right(phi=0) {
    translate([px, 0, pz]) rotate([0, -phi, 0]) translate([0,0,0]) arm_local();
}
module arm_left(phi=0) { mirror([1,0,0]) arm_right(phi); }

// ---------------- slider with foot ring ----------------
// outline of the foot pocket (rounded rectangle), grown by o
module foot2d(o=0) {
    offset(r=o) hull() for (mx=[-1,1], my=[-1,1])
        translate([mx*(Fw - foot_r), my*(Fd - foot_r)]) circle(r=foot_r);
}
module slider() {
    top = pz + pin_d/2 + clr + 2.5;
    difference() {
        union() {
            xzc(S0, S1, 1) hull() {
                translate([-(lx + 2.5 + pin_d/2 + clr + 1), -3]) square([2*(lx + 2.5 + pin_d/2 + clr + 1), 1]);
                for (m=[-1,1]) translate([m*(lx + 1 + pin_d/2 + clr + 2.5 - 5), top - 5]) circle(r=5);
            }
            // bridge from the slider to the foot ring
            translate([-10, S0, -3]) cube([20, cy - S0, 3]);
            // foot ring: floor + rim, open at the front
            difference() {
                translate([0, cy, -3]) hull() {
                    linear_extrude(3 + 4) foot2d(3);
                    linear_extrude(3 + 5) foot2d(2);        // soft chamfered top edge
                }
                translate([0, cy, -3 - 1]) linear_extrude(20) foot2d(-5);   // drain / charging-plug hole
                translate([0, cy, 0]) linear_extrude(20) foot2d(0);         // pocket for the device
                translate([0, cy, 0]) linear_extrude(20) hull() {           // front opening of the rim, rounded
                    for (m=[-1,1]) translate([m*(Fw - 6), Fd - 2]) circle(r=2);
                    translate([-(Fw + 2), Fd + 4]) square([2*(Fw + 2), 1]);
                }
            }
        }
        // horizontal slots for the arm pins
        for (m=[0,1]) mirror([m,0,0]) xz(S0 - 1, S1 + 1)
            hull() for (x=[lx - 0.2, lx + lever*(1 - cos(phi_min)) + 0.4]) translate([x, pz]) circle(d=pin_d + 2*clr);
        // vertical slots for the guide bosses
        for (m=[0,1]) mirror([m,0,0]) xz(S0 - 1, S1 + 1)
            hull() for (z=[gz - travel_up, gz + travel_down]) translate([gx, z]) circle(d=gboss_d + 2*clr);
    }
}

module clip_pivot() snap_clip(groove_d, 10);
module clip_guide() snap_clip(ggroove_d, 9);

// clips in place (in the middle of each groove, opening pointing up)
module hardware() {
    for (m=[0,1]) mirror([m,0,0]) {
        translate([px, bt + at + 0.4, pz]) rotate([-90,0,0]) rotate([0,0,90]) clip_pivot();
        translate([gx, S1 + 0.4, gz]) rotate([-90,0,0]) rotate([0,0,90]) clip_guide();
    }
    if (heads > 0) for (pp = cad_pins)
        translate([pp[0], bt + at + 0.4, pp[1]]) rotate([-90,0,0]) rotate([0,0,90]) clip_pivot();
}

// ---------------- brush head caddy ----------------
// Back plate on the two wing pins, a drained shelf with a ring and a peg per head.
module caddy() if (heads > 0) {
    sh = 3;                       // shelf thickness
    top = bp_z0 + sh;             // shelf top
    difference() {
        union() {
            // back plate
            xzc(bt, bt + at, 0.8) rrect(cad_x0, cad_x0 + cad_w, bp_z0, cad_z1, 6);
            // shelf with rounded front
            translate([0, 0, bp_z0]) linear_extrude(sh) hull() {
                translate([cad_x0, bt]) square([cad_w, 1]);
                for (i=[0:heads-1]) translate([cad_x0 + 4 + hs*(i + 0.5), cad_yc]) circle(r=hr + 1.8);
            }
            for (i=[0:heads-1]) translate([cad_x0 + 4 + hs*(i + 0.5), cad_yc, 0]) {
                // ring that centres the foot
                translate([0, 0, top - 0.01]) difference() {
                    hull() { cylinder(r=hr + 1.8, h=2.5); cylinder(r=hr + 1.2, h=3.2); }
                    translate([0, 0, -1]) cylinder(r=hr, h=10);
                }
                // peg for the drive-pin hole, tapered
                translate([0, 0, top - 0.01]) cylinder(d1=head_hole_d - 0.5, d2=head_hole_d - 1.3, h=10);
            }
        }
        for (i=[0:heads-1]) translate([cad_x0 + 4 + hs*(i + 0.5), cad_yc, 0]) {
            // drain holes around the peg and a gap at the front of the ring
            for (a=[45:90:315]) rotate([0, 0, a]) translate([5.5, 0, bp_z0 - 1]) cylinder(d=3, h=sh + 2, $fn=20);
            translate([-3, hr - 1, top]) cube([6, 4, 5]);
        }
        // holes for the wing pins
        for (pp = cad_pins) translate([pp[0], bt - 1, pp[1]]) rotate([-90,0,0]) cylinder(d=boss_d + 2*clr, h=at + 2);
    }
}
// a brush head standing in the caddy (for checks and pictures)
module brush_heads() if (heads > 0) for (i=[0:heads-1])
    translate([cad_x0 + 4 + hs*(i + 0.5), cad_yc, bp_z0 + 3 + 0.2]) difference() {
        union() {
            cylinder(d1=head_base_d, d2=8, h=12);
            cylinder(d=8, h=60);
            translate([0, 0, 60]) hull() { cylinder(d=8, h=1); translate([0, 0, 20]) cylinder(d=12, h=1); }
        }
        translate([0, 0, -1]) cylinder(d=head_hole_d, h=15); // hole for the drive pin
    }
module device() translate([0, cy, 0]) linear_extrude(120) dev2d(0);

echo(str("preset=", preset, " device ", dev_w, "x", dev_d, " foot ", foot_w, "x", foot_d, " r", foot_r));

// ---------------- views ----------------
module assembly(s=0) {
    phi = asin(s/lever);
    color("#EDEDEA") backplate();
    color("#C9CCD1") translate([0,0,-s]) slider();
    color("#2E3136") { arm_right(phi); arm_left(phi); }
    color("#8A8F96") for (m=[0,1]) mirror([m,0,0]) translate([px,0,pz]) rotate([0,-phi,0]) nuts_in_arm();
    color("#2E3136") hardware();
    if (heads > 0) { color("#C9CCD1") caddy(); %brush_heads(); }
    if (show_device) %device();
}

// print orientations
module print_backplate() rotate([90,0,0]) translate([0,0,0]) backplate();
module print_arm(m)  rotate([90,0,0]) translate([0,-bt,-pz]) mirror([m,0,0]) arm_right(0);
module print_slider() translate([0,0,3]) slider();
module print_caddy() translate([-cad_x0 - cad_w/2, 0, -bp_z0]) caddy();

if (part == "assembly") assembly(s);
else if (part == "backplate") print_backplate();
else if (part == "arm_right") print_arm(0);
else if (part == "arm_left")  print_arm(1);
else if (part == "slider")    print_slider();
else if (part == "clip_pivot") clip_pivot();
else if (part == "clip_guide") clip_guide();
else if (part == "caddy")      print_caddy();
else if (part == "print_plate") {
    print_backplate();
    if (heads > 0) {
        // wide back plate: arms above it, caddy between clips and arms
        translate([52, 46, 0]) print_arm(0);
        translate([138, 46, 0]) print_arm(1);
    } else {
        translate([bp_xr + 12, 0, 0]) print_arm(0);
        translate([bp_xr + 12 + px + cw_x + cw_r + 6.5, -52, 0]) print_arm(1);
    }
    translate([-bp_w/2 - 26, 0, 0]) print_slider();
    for (i=[0:1]) translate([-20 + i*13, 20, 0]) clip_pivot();
    for (i=[0:1]) translate([6 + i*12, 20, 0]) clip_guide();
    if (heads > 0) {
        for (i=[0:1]) translate([32 + i*13, 20, 0]) clip_pivot();
        translate([16, 24, 0]) print_caddy();
    }
}
// assembled single parts (used by the collision check)
else if (part == "asm_backplate") backplate();
else if (part == "asm_slider") translate([0,0,-s]) slider();
else if (part == "asm_arm_right") arm_right(asin(s/lever));
else if (part == "asm_arm_left")  arm_left(asin(s/lever));
else if (part == "asm_hardware") hardware();
else if (part == "asm_device") device();
else if (part == "asm_caddy") { if (heads > 0) caddy(); }
else if (part == "asm_heads") brush_heads();
// explanation view: a pivot pin and its clip just before it clicks into the groove
else if (part == "snap_demo") {
    color("#EDEDEA") { translate([-8, -8, 0]) cube([16, 16, 2]); translate([0, 0, 2]) snap_pin(boss_d, groove_d, at + 0.3 + 2 - 2); }
    color("#2E3136") translate([0, 0, 2]) difference() { cylinder(r=6.5, h=at); translate([0,0,-1]) cylinder(d=boss_d + 2*clr, h=at + 2); }
    color("#8A8F96") translate([-7, 0, 2 + at + 0.4]) rotate([0, 0, 180]) clip_pivot();
}
