"""Check actual wxMSW tab traversal for the text-only Setup pages."""

import os
import unittest


@unittest.skipUnless(os.name == "nt", "Setup keyboard traversal requires Windows")
class SetupNavigationTests(unittest.TestCase):
    def test_text_pages_tab_through_buttons_in_both_directions(self):
        import wx
        from downaudible_windows.settings_views import PAGES, SetupDialog

        application = wx.GetApp() or wx.App(False)
        frame = wx.Frame(None, title="Setup navigation fixture")
        self.addCleanup(frame.Destroy)
        application.SetTopWindow(frame)
        frame.Show()

        steps = (
            (-1, ("Continue", "Skip Setup")),
            (len(PAGES), ("Open DownAudible", "Back", "View DownAudible Help")),
        )
        for index, sequence in steps:
            with self.subTest(index=index), SetupDialog(frame, index) as dialog:
                dialog.Show()
                dialog.Raise()
                wx.YieldIfNeeded()
                primary = wx.Window.FindFocus()
                self.assertIsInstance(primary, wx.Button)

                for flag, order in (
                    (wx.NavigationKeyEvent.IsForward, sequence),
                    (wx.NavigationKeyEvent.IsBackward, (sequence[0], *reversed(sequence[1:]))),
                ):
                    primary.SetFocus()
                    wx.YieldIfNeeded()
                    for label in (*order, order[0]):
                        focus = wx.Window.FindFocus()
                        self.assertIsInstance(focus, wx.Button)
                        self.assertEqual(focus.GetLabel(), label)
                        focus.Navigate(flag)
                        wx.YieldIfNeeded()
