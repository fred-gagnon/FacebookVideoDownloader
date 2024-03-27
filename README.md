# FacebookVideoDownloader

This script allows to download to download videos from Facebook in their original resolution. To use it:

1- Run the script from a PowerShell console then provide your Facebook credential when prompted to do so. Your credential will be saved on disk in an encrypted XML file in `%USERPROFILE%\Documents\Facebook.xml` to be re-used the next time you run the script.

2- When the script asks you for a Facebook video URL, from your favitite web browser, head to `facebook.com` then click on the video you wish to download to make it full screen. Copy the video URL from your browser then paste it in your PowerShell console.

3- If your video is available in multiple resolutions, you will be prompted to select the resolution of the video you wish to download.

4- When prompted, provide the path where you wish to save your video

5- Repeat steps 2-4 as required and when your done, simply press "Enter" in your PowerShell window to exit the script.

**NOTE:**
At one point, Facebook was storing videos and audio in two different files which needed to be recombined.
This operation is automatically supported by the script but it requires ffmpeg to be installed in `ffmpeg\bin\ffmpeg.exe` relative to the script location.
When such is the case, you will be prompted to select the audio track to be downloaded.
I haven't seen this for a while since the downloaded videos now always include both audio and image.
Ffmpeg can be downloaded from here: https://github.com/BtbN/FFmpeg-Builds/releases
