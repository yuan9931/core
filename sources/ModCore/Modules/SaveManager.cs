using dc;
using dc.tool;
using ModCore.Events;
using ModCore.Events.Interfaces.Game.Save;
using ModCore.Storage;
using Newtonsoft.Json.Linq;

namespace ModCore.Modules
{
    [CoreModule(CoreModuleAttribute.CoreModuleKind.Normal)]
    internal class SaveManager : CoreModule<SaveManager>,
        IOnCopySave,
        IOnDeleteSave,
        IOnAfterLoadingSave,
        IOnAfterSavingSave
    {
        private JObject? currentSave;

        public static string GetModdedSavePath( int? slot )
        {
            var name = Save.Class.fileName(slot).ToString();

            return FolderInfo.SaveRoot.GetFilePath(System.IO.Path.ChangeExtension(name, ".modded.json"));
        }

        void IOnCopySave.OnCopySave( IOnCopySave.EventData data )
        {
            var from = GetModdedSavePath(data.SlotFrom);
            var to = GetModdedSavePath(data.SlotTo);
            if (!System.IO.File.Exists(from))
            {
                return;
            }

            // The .modded.json overlay is a secondary file that rides along with the real save.
            // A transient lock on it (antivirus real-time scan, Steam Cloud, or another process
            // touching the just-written save) must never abort the whole save copy: IOnCopySave is
            // broadcast with the default (rethrow) flags, so an exception thrown here crashes the
            // entire game AND prevents the real (.dat) save copy in the hook from running.
            // Retry briefly in case the lock is transient, then give up with a warning and let the
            // real save copy proceed without the overlay.
            for ( var attempt = 0; ; attempt++ )
            {
                try
                {
                    System.IO.File.Copy(from, to, true);
                    return;
                }
                catch ( IOException ex )
                {
                    if ( attempt >= 3 )
                    {
                        Logger.Warning(ex, "Could not copy modded save overlay {From} to {To}; continuing without it.", from, to);
                        return;
                    }
                    System.Threading.Thread.Sleep(150);
                }
            }
        }

        void IOnDeleteSave.OnDeleteSave( int? slot )
        {
            var to = GetModdedSavePath(slot);
            if (!System.IO.File.Exists(to))
            {
                return;
            }
            System.IO.File.Delete(to);
        }

        void IOnAfterLoadingSave.OnAfterLoadingSave( User data )
        {
            var path = GetModdedSavePath(null);
            if (System.IO.File.Exists(path))
            {
                currentSave = JObject.Parse(System.IO.File.ReadAllText(path));
            }
            else
            {
                currentSave = [];
            }
            EventSystem.BroadcastEvent<IOnAfterLoadingModdedSave, Func<string, JObject?>>(name =>
            {
                return currentSave[name] as JObject;
            });
        }

        void IOnAfterSavingSave.OnAfterSavingSave()
        {
            var path = GetModdedSavePath(null);
            currentSave ??= [];
            EventSystem.BroadcastEvent<IOnBeforeSavingModdedSave, Action<string, JObject?>>(( name, data ) =>
            {
                currentSave[name] = data ?? [];
            });
            System.IO.File.WriteAllText(path, currentSave.ToString());
        }
    }
}
