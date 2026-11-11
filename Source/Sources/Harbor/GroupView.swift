import AppKit
final class HarborGroupController: HarborPageController {
    static let size = NSSize(width:420,height:430)
    private var names = [String]()
    private var choices = [NSButton]()
    private var probes = [NSButton]()
    private let summary = harborLabel("",size:11,secondary:true)
    private let empty = harborLabel("尚未选择备用节点",size:13,secondary:true)
    private var edit: NSButton!
    override func loadView() {
        makePage(height:Self.size.height,title:"代理组")
        harborPlaceLabel(summary,in:view,24,52,372,22)
        let list = card(y:84,height:280)
        for i in 0..<5 {
            let choice = NSButton(title:"",target:self,action:#selector(choose(_:)))
            choice.tag=i;choice.isBordered=false;choice.alignment = .left;choice.font = .systemFont(ofSize:12,weight:.medium)
            choice.imagePosition = .imageLeading;choice.cell?.lineBreakMode = .byTruncatingTail
            harborPlace(choice,in:list,12,CGFloat(i)*54+12,260,32);choices.append(choice)
            let probe = harborButton("待测",help:"只测试此节点",target:self,action:#selector(test(_:)))
            probe.tag=i;probe.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
            harborPlace(probe,in:list,284,CGFloat(i)*54+12,80,32);probes.append(probe)
        }
        empty.alignment = .center;harborPlaceLabel(empty,in:list,16,112,348,32)
        edit = action("编辑代理组",symbol:"slider.horizontal.3",help:"从当前机场选择最多5个节点",id:"harbor-edit-group",action:#selector(editGroup))
        harborPlace(edit,in:view,20,380,380,32)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded,let model=owner?.model else{return}
        names=model.failoverNodes;summary.stringValue="\(model.activeSubscriptionName) · \(names.count)/5 个节点"
        empty.isHidden = !names.isEmpty;edit.isEnabled = !model.isBusy
        for i in 0..<5 {
            choices[i].isHidden = i>=names.count;probes[i].isHidden = i>=names.count
            guard i<names.count else{continue}
            let name=names[i];choices[i].title=name
            choices[i].image=harborSymbol(name==model.selectedNode ? "checkmark.circle.fill":"circle",size:14)
            choices[i].contentTintColor=name==model.selectedNode ? .controlAccentColor:.labelColor
            choices[i].isEnabled = !model.isBusy;probes[i].isEnabled = !model.isBusy
            probes[i].title=model.delayText(for:name)
        }
    }
    @objc private func choose(_ sender:NSButton){guard names.indices.contains(sender.tag) else{return};owner?.model.selectNode(names[sender.tag])}
    @objc private func test(_ sender:NSButton){guard names.indices.contains(sender.tag) else{return};owner?.model.testGroupNode(names[sender.tag])}
    @objc private func editGroup(){owner?.navigate(to:.nodes)}
}
