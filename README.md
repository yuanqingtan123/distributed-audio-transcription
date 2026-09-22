# Required Environment Variables
- On Worker Machines
    ```bash
    export controller=<ssh host alias to connect to controller machine>
    export controllerProjectRoot=<path from root to the repo. Eg: /home/user/distributed-audio-transcription>
    ```
- On Controller Machine
    ```bash
    export workerProjectRoot=<path from root to the repo. Eg: /data/data/com.termux/files/home/distributed-audio-transcription>
    ```
