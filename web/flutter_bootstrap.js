{{flutter_js}}
{{flutter_build_config}}

// Comms draws inside #app, which index.html keeps clear of an iPhone's notch and
// home bar. No Flutter offline cache: Comms registers its own worker for
// notifications (push_sw.js) and always loads the newest version.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      hostElement: document.getElementById('app'),
    });
    await appRunner.runApp();
  },
});
