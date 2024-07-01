## Per Object Motion Blur - WIP

### This is a basic implementation of per object motion blur based on:
- https://web.archive.org/web/20130603092822/http://graphics.cs.williams.edu/papers/MotionBlurI3D12/McGuire12Blur.pdf
- http://john-chapman-graphics.blogspot.com/2013/01/per-object-motion-blur.html
- https://github.com/BastiaanOlij/RERadialSunRays/blob/master/radial_sky_rays/radial_sky_rays.gd

### Usage:
Just copy an addon folder to your project. Set a Compositor Effect in your scene Envrionment node to `PerObjectMotionBlur`

### Shader files:
- copy.glsl - makes a copy of orignal color buffer. Needed in reconstruction filter
- tilemax_2step.glsl - executed twice. It's calculating a tilemax from McGuire12Blur in 2pass process. Transposes an output image!! Second pass also converts units of motion vector
- neighbormax.glsl - calculates neighbormax buffer from McGuire12Blur. Result is in UV space
- per-object-motion-blur - reconstruction filter based on  McGuire12Blur.
