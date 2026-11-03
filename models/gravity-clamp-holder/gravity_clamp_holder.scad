// Gravity self-clamping wall holder (electric toothbrush / shaver)
// --------------------------------------------------------------
// How it works: the device stands in the foot ring of the slider.
// Its weight pulls the slider down; the slider pulls the inner lever
// ends of both arms down, so the arms rotate and the two grip pads
// swing inward against the device. Lift the device out and the pads
// open again (pushing the pads apart lifts the slider).
//
// Coordinates: x = right, y = away from the wall, z = up.
// Hardware: 4x M3 countersunk screw (DIN 7991 / ISO 10642: 2x M3x8 for the
// arm pivots, 2x M3x12 for the slider guides), self-tapping into the printed
// bosses. They sit flush in the printed cap washers. Mount the back
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

// measured: Xiaomi Mijia toothbrush, bottom 28.4 x 29.2 mm, round
// measured: Philips OneBlade Pro 360 (QP6541), bottom 34.7 x 33.2 mm, rounded square
P = preset == "mijia"    ? [28.4, 29.2, 30.6, 31.4, 15.3]
  : preset == "oneblade" ? [34.7, 33.2, 36.8, 35.3, 9]
  : [c_dev_w, c_dev_d, c_foot_w, c_foot_d, c_foot_r];
dev_w  = P[0];
dev_d  = P[1];
foot_w = P[2];
foot_d = P[3];
foot_r = min(P[4], foot_w/2, foot_d/2);

/* [Mechanism] */
lever   = 12;   // distance pivot -> lever pin
pad_h   = 30;   // grip pad height
travel_up   = 4;   // slider travel above neutral (opens pads)
travel_down = 3;   // slider travel below neutral (closes pads)

/* [Plates] */
bt   = 4;     // back plate thickness
at   = 4;     // arm thickness
st   = 4;     // slider thickness
gap  = 0.5;   // gap between arm layer and slider layer
clr  = 0.35;  // radial clearance for pins / bosses
wall_screws = false; // add 2 countersunk holes for wall screws
edge = 1.2;   // chamfer on visible front edges (modern look)

/* [View] */
part = "assembly"; // [assembly, backplate, arm_right, arm_left, slider, washer, print_plate]
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
cap_h = 2.5;              // cap washer height (countersunk screw sits flush)
yb  = S1 + 0.3 + cap_h + 1; // back of device (clears the cap washers)
cy  = yb + dev_d/2;       // device centre (y)
Fw  = foot_w/2; Fd = foot_d/2;
pad_front = cy + 9;       // pads reach past the device centre
pin_d = 5;
boss_d = 6;               // arm pivot boss
gx  = 7; gz = 16;         // slider guide bosses (±gx, gz)
gboss_d = 5;              // guide pin diameter
gshoulder_d = 9;
bp_w = 2*(px + 7);        // back plate width
bp_z0 = -3 - travel_down - 1;
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

// ---------------- back plate ----------------
module backplate() {
    difference() {
        union() {
            xzc(0, bt, 1.5) rrect(-bp_w/2, bp_w/2, bp_z0, bp_z1, 10);
            // arm pivot bosses
            for (m=[0,1]) mirror([m,0,0]) translate([px, 0, pz]) rotate([-90,0,0])
                cylinder(d=boss_d, h=bt + at + 0.3);
            // slider guide bosses: shoulder through the arm layer, pin through the slider
            for (m=[0,1]) mirror([m,0,0]) translate([gx, 0, gz]) rotate([-90,0,0]) {
                cylinder(d=gshoulder_d, h=S0);
                cylinder(d=gboss_d, h=S1 + 0.3);
            }
        }
        // M3 pilot holes (self-tapping)
        for (m=[0,1]) mirror([m,0,0]) {
            translate([px, 1.2, pz]) rotate([-90,0,0]) cylinder(d=2.6, h=20, $fn=24);
            translate([gx, 1.2, gz]) rotate([-90,0,0]) cylinder(d=2.6, h=20, $fn=24);
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
            }
            // pin into the slider
            translate([-lever, bt + at - 0.01, 0]) rotate([-90,0,0])
                cylinder(d=pin_d, h=gap + st + 0.01);
            // grip pad: vertical fin facing the device
            difference() {
                // soft rounded fin with chamfered edges: big radius at the front corners
                hull() for (c=[[bt + 1, 8 + 1, 1], [bt + 1, 8 + pad_h - 1, 1],
                               [pad_front - 8, 8 + 8, 8], [pad_front - 8, 8 + pad_h - 8, 8]])
                    translate([-3, c[0], c[1]]) rotate([0,90,0]) {
                        translate([0,0,0.8]) cylinder(r=c[2], h=1.4);
                        cylinder(r=c[2] - 0.8, h=3);
                    }
                // lead-in chamfer at the top inner edge
                translate([-3, bt - 1, 8 + pad_h]) rotate([0, 45, 0]) cube([3, 60, 3], center=false);
            }
        }
        translate([0, bt - 1, 0]) rotate([-90,0,0]) cylinder(d=boss_d + 2*clr, h=at + 2);
    }
}
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

// cap washer: domed, with a 90 deg countersink so an M3 countersunk head sits flush
module washer() {
    difference() {
        hull() { cylinder(d=10, h=cap_h - 0.8); cylinder(d=8.4, h=cap_h); }
        translate([0,0,-1]) cylinder(d=3.4, h=cap_h + 2, $fn=24);
        translate([0,0,cap_h - 1.75]) cylinder(d1=3.4, d2=6.9, h=1.76, $fn=32);
    }
}

// cap washers in place (countersunk screws sit flush inside them)
module hardware() for (m=[0,1]) mirror([m,0,0]) {
    translate([px, bt + at + 0.3, pz]) rotate([-90,0,0]) washer();
    translate([gx, S1 + 0.3, gz]) rotate([-90,0,0]) washer();
}
module device() translate([0, cy, 0]) scale([dev_w/dev_d, 1, 1]) cylinder(d=dev_d, h=120);

echo(str("preset=", preset, " device ", dev_w, "x", dev_d, " foot ", foot_w, "x", foot_d, " r", foot_r));

// ---------------- views ----------------
module assembly(s=0) {
    phi = asin(s/lever);
    color("#EDEDEA") backplate();
    color("#C9CCD1") translate([0,0,-s]) slider();
    color("#2E3136") { arm_right(phi); arm_left(phi); }
    color("#2E3136") hardware();
    if (show_device) %device();
}

// print orientations
module print_backplate() rotate([90,0,0]) translate([0,0,0]) backplate();
module print_arm(m)  rotate([90,0,0]) translate([0,-bt,-pz]) mirror([m,0,0]) arm_right(0);
module print_slider() translate([0,0,3]) slider();

if (part == "assembly") assembly(s);
else if (part == "backplate") print_backplate();
else if (part == "arm_right") print_arm(0);
else if (part == "arm_left")  print_arm(1);
else if (part == "slider")    print_slider();
else if (part == "washer")    washer();
else if (part == "print_plate") {
    print_backplate();
    translate([bp_w/2 + 30, 0, 0]) print_arm(0);
    translate([bp_w/2 + 30, -50, 0]) print_arm(1);
    translate([-bp_w/2 - 30, 0, 0]) print_slider();
    for (i=[0:3]) translate([-20 + i*13, 20, 0]) washer();
}
// assembled single parts (used by the collision check)
else if (part == "asm_backplate") backplate();
else if (part == "asm_slider") translate([0,0,-s]) slider();
else if (part == "asm_arm_right") arm_right(asin(s/lever));
else if (part == "asm_arm_left")  arm_left(asin(s/lever));
else if (part == "asm_hardware") hardware();
else if (part == "asm_device") device();
