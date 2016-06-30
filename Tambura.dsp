declare name "Tambura";
declare description "Pseudo physical model of an Indian Tambura/Tanpura";
declare author "Oli Larkin (contact@olilarkin.co.uk)";
declare copyright "Oliver Larkin";
declare version "1.0";
declare licence "GPL";

//TODO
// - pitch env doesn't get triggered by autoplucker
// - autoplucker fixed to 4 strings

import("math.lib");
import("maxmsp.lib");
import("filter.lib");
import("effect.lib");
import("oscillator.lib");

dtmax = 4096;

ratios(0) = 1.5;
ratios(1) = 2.;
ratios(2) = 2.01;
ratios(3) = 1.;

NStrings = 4;

sm = smooth(tau2pole(0.05)); //50 ms smoothing

pluck(i) = button("/h:trigger/pluck%1i"); // buttons for manual plucking
pluckrate = hslider("/h:trigger/auto pluck rate [style:knob]", 0.1, 0.0, 0.5, 0.001); // automatic plucking rate (Hz)
enableautoplucker = checkbox("/h:trigger/enable auto pluck"); // enable automatic plucking

f0 = hslider("/h:main/[1]sa (root of raga) [style:knob]", 36, 24, 72, 1) : sm : midikey2hz; // the base pitch of the drone
t60 = hslider("/h:main/[2]decay time [style:knob][unit:s]", 10, 0, 100, 0.1) : sm; // how long the strings decay
damp = 1. - hslider("/h:main/[3]high freq loss [style:knob]", 0, 0, 1., 0.01) : sm; // string brightness
fd = hslider("/h:main/[4]harmonic motion [style:knob][scale:exp]", 0.001, 0., 1, 0.0001) : *(0.2) : sm; // controls the detuning of parallel waveguides that mimics harmonic motion of the tambura
coupling = hslider("/h:main/[5]sympathetic coupling [style:knob]", 0.1, 0., 1., 0.0001) : sm; // level of sympathetic coupling between strings
jw = hslider("/h:main/[6]jawari [style:knob]", 0, 0, 1, 0.001) : *(0.1) : sm; // creates the buzzing / jawari effect 
spread = hslider("/h:main/[7]string spread [style:knob]", 1., 0., 1., 0.01) : sm; // stereo spread of strings

ptype = hslider("/h:pick/[1]material [style:knob]", 0.13, 0.0, 1., 0.01) : sm; // cross fades between pink noise and DC excitation
pattack = hslider("/h:pick/[2]attack time [style:knob][scale:exp]", 0.07, 0, 0.5, 0.01); // attack time of pluck envelope, 0 to 0.5 times f0 wavelength
ptime = hslider("/h:pick/[3]decay time [style:knob]", 1., 0.01, 20., 0.01); // decay time (1 to 10 times f0 wavelength)
ppos = hslider("/h:pick/[4]position [style:knob]", 0.25, 0.01, 0.5, 0.01); // pick position (ratio of f0 wavelength)
pbend = hslider("/h:pick/[5]bend depth [style:knob][unit:st]", 3, 0., 12., 0.01); // pick bend depth in semitones
pbendtime = hslider("/h:pick/[6]bend time [style:knob][unit:ms]", 10., 1, 200., 1); // pick bend time (1 to 200 ms)

vol = hslider("volume [unit:dB]", 0, -36, +4, 0.1) : db2linear : sm; // master volume

// s = string index
// c = comb filter index (of 9 comb filters in risset string)
tambura(NStrings) = ( couplingmatrix(NStrings), par(s, NStrings, excitation(s)) : interleave(NStrings, 2) : par(s, NStrings, string(s, pluck(s)))
                    ) // string itself with excitation + fbk as input
                    ~ par(s, NStrings, (!,_)) // feedback only the right waveguide
                    : par(s, NStrings, (+:pan(s)) // add left/right waveguides and pan
                    ) :> _,_ //stereo output
 with {

    couplingmatrix(NStrings) = 
      par(s, NStrings, *(coupling) : couplingfilter) // coupling filters
      <: par(s, NStrings, unsel(NStrings, s) :> _ ) // unsel makes sure the feedback is disconnected

      with {
          unsel(NStrings,s) = par(j, NStrings, U(s,j))
          with {
            U(s,s)=!;
            U(s,j)=_;
          };
          couplingfilter = component("bridgeIR.dsp");
          //couplingfilter = highshelf(1,-100,5000) : peak_eq(14, 2500, 400) : peak_eq(20, 7500, 650); // EQ to simulate bridge response
    };

    //pan(s) = _ <: *(1-v), *(v)
    pan(s) = _ <: *((1-v) : sqrt), *((v) : sqrt)
    with {
      spreadScale = (1/(NStrings-1));
      v = 0.5 + ((spreadScale * s) - 0.5) * spread;
    };

//    excitation(s) = _;
    excitation(s, trig) = input * ampenv : pickposfilter
      with {
        wl = (SR/(f0 * ratios(s))); // wavelength of f0 in samples
        dur = (ptime * wl) / (SR/1000.); // duration of the pluck in ms
        ampenv = trig * line(1. - trig, dur) : lag_ud(wl * pattack * (1/SR), 0.005);
        amprand = abs(noise) : latch(trig) *(0.25) + (0.75);
        posrand = abs(noise) : latch(trig) *(0.2);
        input = 1., pink_noise : interpolate(ptype); // crossfade between DC and pink noise excitation source
        pickposfilter = ffcombfilter(dtmax, ((ppos + posrand) * wl), -1); // simulation of different pluck positions
      };

    string(s, trig) = _, _ <: +, !,_ : rissetstring(_, s), rissetstring(_, s) // dual risset strings for decoupled feedback
    with {
      rissetstring(x, s) = _ <: par(c, 9, stringloop(x, s, c)) :> _ : dcblocker *(0.01); // 9 detuned waveguide resonators in parallel
      stringloop(x, s, c) = (+ : delay) ~ ((dampingfilter : nlfm) * fbk) // all-pass interpolated waveguide with damping filter and non linear apf for jawari effect
      with {
        //delay = fdelay1a(dtmax, dtsamples, x); // allpass interpolation has better HF response
        delay = fdelaylti(2, dtmax, dtsamples,x); // lagrange interpolation glitches less with pitch envelope
        pitchenv = trig * line(1. - trig, pbendtime) <: * : *(pbend);
        thisf0 = pianokey2hz( hz2pianokey((f0 * ratios(s)) + ((c-4) * fd) + pitchenv) );
        dtsamples = (SR/thisf0) - 2;
        fbk = pow(0.001,1.0/(thisf0*t60));
        dampingfilter(x) = (h0 * x' + h1*(x+x''))
        with {
          h0 = (1. + damp)/2;
          h1 = (1. - damp)/4;
        };
        nlfm(x) = x <: allpassnn(1,(par(i,1,jw * PI * x)));
      };
    };
};

autoplucker= phasor(pluckrate) <: <(0.25), >(0.25) & <(0.5), >(0.5) & <(0.75), >(0.75) & <(1) : par(s, NStrings, *(enableautoplucker))
with {
  phasor(freq) = (freq/float(SR) : (+ : decimal) ~ _);
};

process = (par(s, NStrings, pluck(s)), autoplucker) :> tambura(NStrings) : *(vol), *(vol);