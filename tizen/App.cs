using Tizen.Flutter.Embedding;

namespace Runner
{
    public class App : FlutterApplication
    {
        protected override void OnCreate()
        {
            // The video_player_avplay CAPI backend renders on a hardware overlay
            // plane BELOW Flutter and shows through the VideoPlayer widget's Hole.
            // That requires a transparent Flutter window; flutter-tizen defaults it
            // to opaque, which makes the video plane invisible (black). Must be set
            // before base.OnCreate() creates the window.
            IsWindowTransparent = true;

            base.OnCreate();

            GeneratedPluginRegistrant.RegisterPlugins(this);
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }
}
