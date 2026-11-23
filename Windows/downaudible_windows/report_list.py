"""Native report lists that adapt one column to the available space."""

import wx


def report_list(parent, name, columns, *, fill, style=0):
    control = wx.ListCtrl(parent, style=wx.LC_REPORT | style, name=name)
    if wx.Platform == "__WXMSW__":
        control.SetAccessibleName(name)
    for title, width in columns:
        control.AppendColumn(title, width=control.FromDIP(width))

    auto_size = True

    def resize():
        if not control or not auto_size:
            return
        fixed_width = sum(control.GetColumnWidth(index) for index in range(len(columns)) if index != fill)
        width = max(control.FromDIP(columns[fill][1]), control.GetClientSize().width - fixed_width)
        if control.GetColumnWidth(fill) != width:
            control.SetColumnWidth(fill, width)

    def size_changed(event):
        event.Skip()
        wx.CallAfter(resize)

    def column_resized(event):
        nonlocal auto_size
        if event.GetColumn() == fill:
            auto_size = False
        event.Skip()

    control.Bind(wx.EVT_SIZE, size_changed)
    control.Bind(wx.EVT_LIST_COL_END_DRAG, column_resized)
    return control
