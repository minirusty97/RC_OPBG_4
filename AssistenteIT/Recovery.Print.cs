using System;
using System.Drawing;
using System.Drawing.Printing;
using System.Windows.Forms;

namespace AssistenteIT {
    public static class RecoveryPrinter {
        public static int DrawPage(Graphics graphics, RectangleF bounds, string text, int offset) {
            if (text == null || offset < 0 || offset > text.Length) throw new ArgumentException("Testo di stampa non valido.");
            if (offset == text.Length) return offset;
            using (var font = new Font("Consolas", 9))
            using (var format = new StringFormat()) {
                format.FormatFlags = StringFormatFlags.LineLimit;
                int characters, lines;
                string remaining = text.Substring(offset);
                graphics.MeasureString(remaining, font, bounds.Size, format, out characters, out lines);
                if (characters <= 0) throw new InvalidOperationException("Area di stampa insufficiente.");
                graphics.DrawString(remaining.Substring(0, characters), font, Brushes.Black, bounds, format);
                return offset + characters;
            }
        }
        public static bool Print(string text, IWin32Window owner) {
            if (String.IsNullOrWhiteSpace(text)) throw new ArgumentException("Nessun testo da stampare.");
            using (var document = new PrintDocument())
            using (var dialog = new PrintDialog()) {
                int offset = 0;
                document.DocumentName = "Chiavi BitLocker - Assistente IT";
                document.DefaultPageSettings.Margins = new Margins(50, 50, 50, 50);
                document.BeginPrint += delegate { offset = 0; };
                document.PrintPage += delegate(object sender, PrintPageEventArgs page) {
                    offset = DrawPage(page.Graphics, page.MarginBounds, text, offset);
                    page.HasMorePages = offset < text.Length;
                };
                dialog.Document = document; dialog.UseEXDialog = true;
                dialog.AllowSomePages = false; dialog.AllowCurrentPage = false;
                if (dialog.ShowDialog(owner) != DialogResult.OK) return false;
                document.Print(); return true;
            }
        }
    }
}
