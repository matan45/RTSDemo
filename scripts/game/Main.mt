 import * from "engine/Log.mt";
 import * from "engine/Entity.mt";

 @Script
 public class Main {
     private int selfId;

     constructor() {
         // initialization code
     }

     public function onStart(): void {
         this.selfId = Entity::self();
         Log::info("Hello from Main script!");
     }

     public function onUpdate(float deltaTime): void {
         // Called every frame
     }

     public function onFixedUpdate(float fixedDeltaTime): void {
         // Called at fixed time intervals (after each physics step)
     }

     public function onLateUpdate(float deltaTime): void {
         // Called after all onUpdate calls (e.g. camera follow)
     }

     public function onDestroy(): void {
         // Called when script is destroyed
     }
 }
 