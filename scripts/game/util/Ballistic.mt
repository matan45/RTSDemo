// Ballistic - projectile-motion launch-velocity solvers for thrown things
// (grenades, lobbed shells, arcing tracers). Pure math; no engine calls.
//
// Each solver returns the initial velocity to give a DYNAMIC physics body so that,
// under constant gravity, it travels from `origin` to `target`. Hand the result to
// Physics::setLinearVelocity after Physics::createBody and gravity does the arc.
//
// `gravity` is the POSITIVE magnitude of downward acceleration (use Ballistic.GRAVITY,
// ~9.81, and match it to the engine's physics gravity for the throw to land precisely;
// or just tune flightTime/apexHeight visually).
//
// NOTE: `from` is a reserved word in mType (import ... from), so the launch point is
// named `origin` here.
//
// Usage (in a throw script, at the release moment):
//   Vec3f origin = Socket::getPosition(soldierId, "Hand_R");
//   Vec3f target = Entity::getPosition(targetId);
//   Vec3f v      = Ballistic::velocityForTime(origin, target, 1.2, Ballistic.GRAVITY);
//   Physics::createBody(grenadeId);
//   Physics::setLinearVelocity(grenadeId, v);
//
// Math reference: position(t) = p0 + v*t + 0.5*a*t^2, with a = (0, -gravity, 0).

import * from "../../lib/math/Vec3f.mt";

public class Ballistic {
    // Default downward acceleration magnitude (m/s^2). Match to the engine physics
    // gravity if you want pixel-perfect landings.
    public static final float GRAVITY = 9.81;

    public constructor() {
    }

    // --- A1: fixed flight time (always solvable) ---------------------------------
    // Velocity to travel from `origin` to `target` in exactly `flightTime` seconds.
    // Lower time = flatter/faster; higher time = lazier lob. Any target is reachable
    // by adjusting flightTime, so this never fails. flightTime must be > 0.
    public static function velocityForTime(Vec3f origin, Vec3f target, float flightTime, float gravity): Vec3f {
        if (flightTime < 0.0001) {
            return Vec3f::zero();
        }
        Vec3f d = target.subtract(origin);
        float vx = d.x / flightTime;
        float vz = d.z / flightTime;
        // p1.y = p0.y + vy*t - 0.5*g*t^2  =>  vy = d.y/t + 0.5*g*t
        float vy = d.y / flightTime + 0.5 * gravity * flightTime;
        return new Vec3f(vx, vy, vz);
    }

    // --- A2: fixed launch speed, solve the angle (real range limit) --------------
    // Velocity at constant `speed`, or null if the target is out of range (or a
    // straight-up/down throw). highArc=false picks the flat/direct shot; highArc=true
    // picks the lobbed shot over the same distance.
    public static function velocityForSpeed(Vec3f origin, Vec3f target, float speed, float gravity, bool highArc): Vec3f? {
        Vec3f d = target.subtract(origin);
        Vec3f flat = new Vec3f(d.x, 0.0, d.z);
        float r = flat.length();          // horizontal distance
        if (r < 0.0001) {
            return null;                  // directly above/below: no horizontal solution
        }
        float h = d.y;                    // vertical delta
        float s2 = speed * speed;
        float disc = s2 * s2 - gravity * (gravity * r * r + 2.0 * h * s2);
        if (disc < 0.0) {
            return null;                  // unreachable at this speed
        }
        float root = sqrt(disc);
        float tanTheta = 0.0;
        if (highArc) {
            tanTheta = (s2 + root) / (gravity * r);
        } else {
            tanTheta = (s2 - root) / (gravity * r);
        }
        Vec3f dir = flat.normalize();
        float vHoriz = speed / sqrt(1.0 + tanTheta * tanTheta); // speed*cos(theta)
        Vec3f horiz = dir.multiply(vHoriz);
        return new Vec3f(horiz.x, vHoriz * tanTheta, horiz.z);   // y = speed*sin(theta)
    }

    // --- A3: lob over a chosen apex height (great for grenades / clearing cover) --
    // Velocity that peaks `apexHeight` units ABOVE the launch point, then drops onto
    // the target. Returns null if apexHeight <= 0 or the apex is below the target
    // (can't fall onto it). apexHeight controls how high the arc is.
    public static function velocityForApex(Vec3f origin, Vec3f target, float apexHeight, float gravity): Vec3f? {
        if (apexHeight <= 0.0) {
            return null;
        }
        float peakAboveTarget = (origin.y + apexHeight) - target.y;
        if (peakAboveTarget < 0.0) {
            return null;                  // target is above the requested apex
        }
        float vy = sqrt(2.0 * gravity * apexHeight);   // up-velocity to reach the apex
        float tUp = vy / gravity;                       // time launch -> apex
        float tDown = sqrt(2.0 * peakAboveTarget / gravity); // time apex -> target
        float total = tUp + tDown;
        if (total < 0.0001) {
            return Vec3f::zero();
        }
        Vec3f d = target.subtract(origin);
        Vec3f flat = new Vec3f(d.x, 0.0, d.z);
        Vec3f horiz = flat.divide(total);               // horizontal component
        return new Vec3f(horiz.x, vy, horiz.z);
    }
}
