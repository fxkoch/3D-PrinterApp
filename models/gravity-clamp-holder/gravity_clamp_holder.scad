// Gravity self-clamping wall holder (electric toothbrush / shaver)
// --------------------------------------------------------------
// How it works: the device stands in the foot ring of the slider.
// Its weight pulls the slider down; the slider pulls the inner lever
// ends of both arms down, so the arms rotate and the two grip pads
// swing inward against the device. Lift the device out and the pads
// open again (pushing the pads apart lifts the slider).
//
// Coordinates: x = right, y = away from the wall, z = up.
// Hardware: 4x M3 screw (2x M3x8 for the arm pivots, 2x M3x12 for the
// slider guides), self-tapping into the printed bosses. Mount the back
// plate with double-sided foam tape (or the optional screw holes).
//
// Render a single part with:  openscad -D 'part="arm_right"' -o x.stl this.scad

/* [Device] */
dev_w   = 30;   // width of the device at grip height (mm)
dev_d   = 30;   // depth of the device (front to back, mm)
foot_d  = 32;   // inner diameter of the foot ring (a bit bigger than the device bottom)

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
yb  = S1 + 0.3 + 2 + 3 + 1.2; // back of device (clears washer + M3 head)
cy  = yb + dev_d/2;       // device centre (y)
Rf  = foot_d/2;
pad_front = cy + 8;       // pads reach past the device centre
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

// ---------------- back plate ----------------
module backplate() {
    difference() {
        union() {
            xz(0, bt) rrect(-bp_w/2, bp_w/2, bp_z0, bp_z1, 5);
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
            xz(bt, bt + at) {
                hull() { circle(r=6); translate([-lever, 0]) circle(r=4); }       // lever
                hull() { circle(r=6); translate([-3, 0]) square([6, H]); }      // upright
            }
            // pin into the slider
            translate([-lever, bt + at - 0.01, 0]) rotate([-90,0,0])
                cylinder(d=pin_d, h=gap + st + 0.01);
            // grip pad: vertical fin facing the device
            difference() {
                hull() {
                    translate([-3, bt, 8]) cube([3, 1, pad_h]);
                    translate([-3, pad_front - 3, 8 + 3]) rotate([0,90,0]) cylinder(r=3, h=3);
                    translate([-3, pad_front - 3, 8 + pad_h - 3]) rotate([0,90,0]) cylinder(r=3, h=3);
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
module slider() {
    top = pz + pin_d/2 + clr + 2.5;
    difference() {
        union() {
            xz(S0, S1) hull() {
                translate([-(lx + 2.5 + pin_d/2 + clr + 1), -3]) square([2*(lx + 2.5 + pin_d/2 + clr + 1), 1]);
                for (m=[-1,1]) translate([m*(lx + 1 + pin_d/2 + clr + 2.5 - 3), top - 3]) circle(r=3);
            }
            // bridge from the slider to the foot ring
            translate([-10, S0, -3]) cube([20, cy - S0, 3]);
            // foot ring: floor + rim, open at the front
            difference() {
                translate([0, cy, -3]) union() {
                    cylinder(r=Rf + 3, h=3);
                    cylinder(r=Rf + 3, h=3 + 5);
                }
                translate([0, cy, -3 - 1]) cylinder(r=Rf - 5, h=20);   // drain / cable hole
                translate([0, cy, 0]) cylinder(r=Rf, h=20);            // pocket for the device
                translate([-(Rf - 4), cy, 0]) cube([2*(Rf - 4), Rf + 10, 20]); // front opening of the rim
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

module washer() { difference() { cylinder(d=10, h=2); translate([0,0,-1]) cylinder(d=3.4, h=4, $fn=24); } }

// screws + washers in place (pan head M3: d 5.5, h 3)
module hardware() for (m=[0,1]) mirror([m,0,0]) {
    translate([px, bt + at + 0.3, pz]) rotate([-90,0,0]) { washer(); translate([0,0,2]) cylinder(d=5.5, h=3); }
    translate([gx, S1 + 0.3, gz]) rotate([-90,0,0]) { washer(); translate([0,0,2]) cylinder(d=5.5, h=3); }
}
module device() translate([0, cy, 0]) scale([dev_w/dev_d, 1, 1]) cylinder(d=dev_d, h=120);

// ---------------- views ----------------
module assembly(s=0) {
    phi = asin(s/lever);
    color("SaddleBrown") backplate();
    color("Tan") translate([0,0,-s]) slider();
    color("Peru") { arm_right(phi); arm_left(phi); }
    color("Gray") hardware();
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
