import Foundation

/// 16-bit QMK keycode -> the string the Vial GUI writes into a `.vil` for Vial protocol 6.
///
/// Mirrors `Keycode.serialize` of vial-gui (keycodes/keycodes.py + keycodes_v6.py); the numeric
/// ranges agree with quantum/keycodes.h of vial-qmk (QK_MODS 0x0100, QK_MOD_TAP 0x2000,
/// QK_LAYER_TAP 0x4000, QK_TO 0x5200 ... QK_PERSISTENT_DEF_LAYER 0x52E0, QK_TAP_DANCE 0x5700,
/// QK_MACRO 0x7700, QK_KB 0x7E00):
/// - a code whose high byte is a "masked" wrapper (`LSFT(kc)`, `LGUI_T(kc)`, `LT3(kc)`) becomes
///   wrapper + the name of the low byte, e.g. `LSFT(KC_9)`, `LT1(KC_BSPACE)`;
/// - anything else is looked up as a whole: fixed names, plus the families the GUI generates
///   per keyboard (`MO(n)`... for existing layers only, `M0`..., `TD(n)`, `USER00`...);
/// - a code without a name is Python's `hex()`: lowercase, no padding (`0x5227`). That is also
///   what the GUI writes, and `Keycode.label` shows it as is.
enum VialKeycodes {
    /// What the GUI knows about the keyboard when it names keycodes.
    struct Context: Equatable {
        var layers = 32
        var macros = 16
        /// Number of `USERnn` names: the size of `customKeycodes` in the definition, 16 without one.
        var userKeycodes = 16
        /// "basic" / "advanced" from the definition's `midi`, nil = no MIDI names.
        var midi: String? = nil
    }

    static func name(_ code: UInt16, context: Context = Context()) -> String {
        let high = UInt8(code >> 8), low = code & 0xFF
        if high >= 0x40, high <= 0x4F {
            // LT0..LT15 are all masked, but only existing layers have a name.
            let layer = Int(high & 0x0F)
            guard layer < min(context.layers, 16), let inner = plainName(low, context) else { return hex(code) }
            return "LT\(layer)(\(inner))"
        }
        if let wrapper = wrappers[high] {
            guard let inner = plainName(low, context) else { return hex(code) }
            return "\(wrapper)(\(inner))"
        }
        return plainName(code, context) ?? hex(code)
    }

    static func hex(_ code: UInt16) -> String { "0x" + String(code, radix: 16) }

    private static func plainName(_ code: UInt16, _ ctx: Context) -> String? {
        if let fixed = plain[code] { return fixed }
        let c = Int(code)
        // Layer switches, 32 codes each, only for layers the keyboard has.
        for (base, name) in layerFamilies where c >= base && c < base + 32 {
            return c - base < ctx.layers ? "\(name)(\(c - base))" : nil
        }
        switch c {
        case 0x5700...0x57FF: return "TD(\(c - 0x5700))"
        case 0x7700...0x77FF: return c - 0x7700 < ctx.macros ? "M\(c - 0x7700)" : nil
        case 0x7E00...0x7E3F:
            return c - 0x7E00 < ctx.userKeycodes ? "USER" + (c - 0x7E00 < 10 ? "0" : "") + "\(c - 0x7E00)" : nil
        case 0x7C7B: return "QK_LAYER_LOCK"
        case 0x7C77: return ctx.layers >= 4 ? "FN_MO13" : nil
        case 0x7C78: return ctx.layers >= 4 ? "FN_MO23" : nil
        default: break
        }
        if ctx.midi == "basic" || ctx.midi == "advanced", let m = midiBasic[code] { return m }
        if ctx.midi == "advanced", let m = midiAdvanced[code] { return m }
        return nil
    }

    private static let layerFamilies: [(Int, String)] = [
        (0x5200, "TO"), (0x5220, "MO"), (0x5240, "DF"), (0x5260, "TG"),
        (0x5280, "OSL"), (0x52C0, "TT"), (0x52E0, "PDF"),
    ]

    private static func table(_ text: String) -> [UInt16: String] {
        var out: [UInt16: String] = [:]
        for item in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let eq = item.firstIndex(of: "="), let code = UInt16(item[..<eq], radix: 16) else { continue }
            out[code] = String(item[item.index(after: eq)...])
        }
        return out
    }

    private static let plain = table(plainTable)
    private static let midiBasic = table(midiBasicTable)
    private static let midiAdvanced = table(midiAdvancedTable)
    private static let wrappers: [UInt8: String] = {
        var out: [UInt8: String] = [:]
        for (code, name) in table(wrapperTable) { out[UInt8(code)] = name }
        return out
    }()

    // Generated from vial-gui: every `K("...")` id of the fixed keycode lists, resolved through
    // keycodes_v6.kc ("hex code=name"). Ids that fall under a masked high byte (KC_TILD = 0x235,
    // the GUI writes LSFT(KC_GRAVE)) are left out, as the GUI never looks them up.
    static let plainTable = """
        0=KC_NO 1=KC_TRNS 4=KC_A 5=KC_B 6=KC_C 7=KC_D 8=KC_E 9=KC_F A=KC_G B=KC_H C=KC_I D=KC_J E=KC_K F=KC_L 10=KC_M
        11=KC_N 12=KC_O 13=KC_P 14=KC_Q 15=KC_R 16=KC_S 17=KC_T 18=KC_U 19=KC_V 1A=KC_W 1B=KC_X 1C=KC_Y 1D=KC_Z 1E=KC_1
        1F=KC_2 20=KC_3 21=KC_4 22=KC_5 23=KC_6 24=KC_7 25=KC_8 26=KC_9 27=KC_0 28=KC_ENTER 29=KC_ESCAPE 2A=KC_BSPACE
        2B=KC_TAB 2C=KC_SPACE 2D=KC_MINUS 2E=KC_EQUAL 2F=KC_LBRACKET 30=KC_RBRACKET 31=KC_BSLASH 32=KC_NONUS_HASH
        33=KC_SCOLON 34=KC_QUOTE 35=KC_GRAVE 36=KC_COMMA 37=KC_DOT 38=KC_SLASH 39=KC_CAPSLOCK 3A=KC_F1 3B=KC_F2
        3C=KC_F3 3D=KC_F4 3E=KC_F5 3F=KC_F6 40=KC_F7 41=KC_F8 42=KC_F9 43=KC_F10 44=KC_F11 45=KC_F12 46=KC_PSCREEN
        47=KC_SCROLLLOCK 48=KC_PAUSE 49=KC_INSERT 4A=KC_HOME 4B=KC_PGUP 4C=KC_DELETE 4D=KC_END 4E=KC_PGDOWN 4F=KC_RIGHT
        50=KC_LEFT 51=KC_DOWN 52=KC_UP 53=KC_NUMLOCK 54=KC_KP_SLASH 55=KC_KP_ASTERISK 56=KC_KP_MINUS 57=KC_KP_PLUS
        58=KC_KP_ENTER 59=KC_KP_1 5A=KC_KP_2 5B=KC_KP_3 5C=KC_KP_4 5D=KC_KP_5 5E=KC_KP_6 5F=KC_KP_7 60=KC_KP_8
        61=KC_KP_9 62=KC_KP_0 63=KC_KP_DOT 64=KC_NONUS_BSLASH 65=KC_APPLICATION 67=KC_KP_EQUAL 68=KC_F13 69=KC_F14
        6A=KC_F15 6B=KC_F16 6C=KC_F17 6D=KC_F18 6E=KC_F19 6F=KC_F20 70=KC_F21 71=KC_F22 72=KC_F23 73=KC_F24 74=KC_EXEC
        75=KC_HELP 77=KC_SLCT 78=KC_STOP 79=KC_AGIN 7A=KC_UNDO 7B=KC_CUT 7C=KC_COPY 7D=KC_PSTE 7E=KC_FIND 80=KC__VOLUP
        81=KC__VOLDOWN 82=KC_LCAP 83=KC_LNUM 84=KC_LSCR 85=KC_KP_COMMA 87=KC_RO 88=KC_KANA 89=KC_JYEN 8A=KC_HENK
        8B=KC_MHEN 90=KC_LANG1 91=KC_LANG2 A5=KC_PWR A6=KC_SLEP A7=KC_WAKE A8=KC_MUTE A9=KC_VOLU AA=KC_VOLD AB=KC_MNXT
        AC=KC_MPRV AD=KC_MSTP AE=KC_MPLY AF=KC_MSEL B0=KC_EJCT B1=KC_MAIL B2=KC_CALC B3=KC_MYCM B4=KC_WSCH B5=KC_WHOM
        B6=KC_WBAK B7=KC_WFWD B8=KC_WSTP B9=KC_WREF BA=KC_WFAV BB=KC_MFFD BC=KC_MRWD BD=KC_BRIU BE=KC_BRID CD=KC_MS_U
        CE=KC_MS_D CF=KC_MS_L D0=KC_MS_R D1=KC_BTN1 D2=KC_BTN2 D3=KC_BTN3 D4=KC_BTN4 D5=KC_BTN5 D9=KC_WH_U DA=KC_WH_D
        DB=KC_WH_L DC=KC_WH_R DD=KC_ACL0 DE=KC_ACL1 DF=KC_ACL2 E0=KC_LCTRL E1=KC_LSHIFT E2=KC_LALT E3=KC_LGUI
        E4=KC_RCTRL E5=KC_RSHIFT E6=KC_RALT E7=KC_RGUI 52A1=OSM(MOD_LCTL) 52A2=OSM(MOD_LSFT)
        52A3=OSM(MOD_LCTL|MOD_LSFT) 52A4=OSM(MOD_LALT) 52A5=OSM(MOD_LCTL|MOD_LALT) 52A6=OSM(MOD_LSFT|MOD_LALT)
        52A7=OSM(MOD_MEH) 52A8=OSM(MOD_LGUI) 52A9=OSM(MOD_LCTL|MOD_LGUI) 52AA=OSM(MOD_LSFT|MOD_LGUI)
        52AB=OSM(MOD_LCTL|MOD_LSFT|MOD_LGUI) 52AC=OSM(MOD_LALT|MOD_LGUI) 52AD=OSM(MOD_LCTL|MOD_LALT|MOD_LGUI)
        52AE=OSM(MOD_LSFT|MOD_LALT|MOD_LGUI) 52AF=OSM(MOD_HYPR) 52B1=OSM(MOD_RCTL) 52B2=OSM(MOD_RSFT)
        52B3=OSM(MOD_RCTL|MOD_RSFT) 52B4=OSM(MOD_RALT) 52B5=OSM(MOD_RCTL|MOD_RALT) 52B6=OSM(MOD_RSFT|MOD_RALT)
        52B7=OSM(MOD_RCTL|MOD_RSFT|MOD_RALT) 52B8=OSM(MOD_RGUI) 52B9=OSM(MOD_RCTL|MOD_RGUI) 52BA=OSM(MOD_RSFT|MOD_RGUI)
        52BB=OSM(MOD_RCTL|MOD_RSFT|MOD_RGUI) 52BC=OSM(MOD_RALT|MOD_RGUI) 52BD=OSM(MOD_RCTL|MOD_RALT|MOD_RGUI)
        52BE=OSM(MOD_RSFT|MOD_RALT|MOD_RGUI) 52BF=OSM(MOD_RCTL|MOD_RSFT|MOD_RALT|MOD_RGUI)
        7000=MAGIC_SWAP_CONTROL_CAPSLOCK 7001=MAGIC_UNSWAP_CONTROL_CAPSLOCK 7003=MAGIC_UNCAPSLOCK_TO_CONTROL
        7004=MAGIC_CAPSLOCK_TO_CONTROL 7005=MAGIC_SWAP_LALT_LGUI 7006=MAGIC_UNSWAP_LALT_LGUI 7007=MAGIC_SWAP_RALT_RGUI
        7008=MAGIC_UNSWAP_RALT_RGUI 7009=MAGIC_UNNO_GUI 700A=MAGIC_NO_GUI 700B=MAGIC_TOGGLE_GUI
        700C=MAGIC_SWAP_GRAVE_ESC 700D=MAGIC_UNSWAP_GRAVE_ESC 700E=MAGIC_SWAP_BACKSLASH_BACKSPACE
        700F=MAGIC_UNSWAP_BACKSLASH_BACKSPACE 7011=MAGIC_HOST_NKRO 7012=MAGIC_UNHOST_NKRO 7013=MAGIC_TOGGLE_NKRO
        7014=MAGIC_SWAP_ALT_GUI 7015=MAGIC_UNSWAP_ALT_GUI 7016=MAGIC_TOGGLE_ALT_GUI 7017=MAGIC_SWAP_LCTL_LGUI
        7018=MAGIC_UNSWAP_LCTL_LGUI 7019=MAGIC_SWAP_RCTL_RGUI 701A=MAGIC_UNSWAP_RCTL_RGUI 701B=MAGIC_SWAP_CTL_GUI
        701C=MAGIC_UNSWAP_CTL_GUI 701D=MAGIC_TOGGLE_CTL_GUI 701E=MAGIC_EE_HANDS_LEFT 701F=MAGIC_EE_HANDS_RIGHT
        7480=AU_ON 7481=AU_OFF 7482=AU_TOG 748A=CLICKY_TOGGLE 748D=CLICKY_UP 748E=CLICKY_DOWN 748F=CLICKY_RESET
        7490=MU_ON 7491=MU_OFF 7492=MU_TOG 7493=MU_MOD 7800=BL_ON 7801=BL_OFF 7802=BL_TOGG 7803=BL_DEC 7804=BL_INC
        7805=BL_STEP 7806=BL_BRTG 7820=RGB_TOG 7821=RGB_MOD 7822=RGB_RMOD 7823=RGB_HUI 7824=RGB_HUD 7825=RGB_SAI
        7826=RGB_SAD 7827=RGB_VAI 7828=RGB_VAD 7829=RGB_SPI 782A=RGB_SPD 782B=RGB_M_P 782C=RGB_M_B 782D=RGB_M_R
        782E=RGB_M_SW 782F=RGB_M_SN 7830=RGB_M_K 7831=RGB_M_X 7832=RGB_M_G 7833=RGB_M_T 7840=RM_ON 7841=RM_OFF
        7842=RM_TOGG 7843=RM_NEXT 7844=RM_PREV 7845=RM_HUEU 7846=RM_HUED 7847=RM_SATU 7848=RM_SATD 7849=RM_VALU
        784A=RM_VALD 784B=RM_SPDU 784C=RM_SPDD 7C00=QK_BOOT 7C01=QK_REBOOT 7C03=QK_CLEAR_EEPROM 7C10=KC_ASDN
        7C11=KC_ASUP 7C12=KC_ASRP 7C13=KC_ASON 7C14=KC_ASOFF 7C15=KC_ASTG 7C16=KC_GESC 7C18=KC_LCPO 7C19=KC_RCPC
        7C1A=KC_LSPO 7C1B=KC_RSPC 7C1C=KC_LAPO 7C1D=KC_RAPC 7C1E=KC_SFTENT 7C40=HPT_ON 7C41=HPT_OFF 7C42=HPT_TOG
        7C43=HPT_RST 7C44=HPT_FBK 7C45=HPT_BUZ 7C46=HPT_MODI 7C47=HPT_MODD 7C48=HPT_CONT 7C49=HPT_CONI 7C4A=HPT_COND
        7C4B=HPT_DWLI 7C4C=HPT_DWLD 7C50=CMB_ON 7C51=CMB_OFF 7C52=CMB_TOG 7C53=DYN_REC_START1 7C54=DYN_REC_START2
        7C55=DYN_REC_STOP 7C56=DYN_MACRO_PLAY1 7C57=DYN_MACRO_PLAY2 7C73=QK_CAPS_WORD_TOGGLE 7C79=QK_REPEAT_KEY
        7C7A=QK_ALT_REPEAT_KEY
        """
    static let wrapperTable = """
        01=LCTL 02=LSFT 03=C_S 04=LALT 05=LCA 06=LSA 07=MEH 08=LGUI 09=LCG 0A=SGUI 0C=LAG 0D=LCAG 0F=HYPR 11=RCTL
        12=RSFT 14=RALT 18=RGUI 19=RCG 21=LCTL_T 22=LSFT_T 23=C_S_T 24=LALT_T 25=LCA_T 26=LSA_T 27=MEH_T 28=LGUI_T
        29=LCG_T 2A=SGUI_T 2C=LAG_T 2D=LCAG_T 2F=ALL_T 31=RCTL_T 32=RSFT_T 34=RALT_T 38=RGUI_T 39=RCG_T 3D=RCAG_T
        """
    static let midiBasicTable = """
        7103=MI_C 7104=MI_Cs 7105=MI_D 7106=MI_Ds 7107=MI_E 7108=MI_F 7109=MI_Fs 710A=MI_G 710B=MI_Gs 710C=MI_A
        710D=MI_As 710E=MI_B 710F=MI_C_1 7110=MI_Cs_1 7111=MI_D_1 7112=MI_Ds_1 7113=MI_E_1 7114=MI_F_1 7115=MI_Fs_1
        7116=MI_G_1 7117=MI_Gs_1 7118=MI_A_1 7119=MI_As_1 711A=MI_B_1 711B=MI_C_2 711C=MI_Cs_2 711D=MI_D_2 711E=MI_Ds_2
        711F=MI_E_2 7120=MI_F_2 7121=MI_Fs_2 7122=MI_G_2 7123=MI_Gs_2 7124=MI_A_2 7125=MI_As_2 7126=MI_B_2 7127=MI_C_3
        7128=MI_Cs_3 7129=MI_D_3 712A=MI_Ds_3 712B=MI_E_3 712C=MI_F_3 712D=MI_Fs_3 712E=MI_G_3 712F=MI_Gs_3 7130=MI_A_3
        7131=MI_As_3 7132=MI_B_3 7133=MI_C_4 7134=MI_Cs_4 7135=MI_D_4 7136=MI_Ds_4 7137=MI_E_4 7138=MI_F_4 7139=MI_Fs_4
        713A=MI_G_4 713B=MI_Gs_4 713C=MI_A_4 713D=MI_As_4 713E=MI_B_4 713F=MI_C_5 7140=MI_Cs_5 7141=MI_D_5 7142=MI_Ds_5
        7143=MI_E_5 7144=MI_F_5 7145=MI_Fs_5 7146=MI_G_5 7147=MI_Gs_5 7148=MI_A_5 7149=MI_As_5 714A=MI_B_5
        7185=MI_ALLOFF
        """
    static let midiAdvancedTable = """
        714B=MI_OCT_N2 714C=MI_OCT_N1 714D=MI_OCT_0 714E=MI_OCT_1 714F=MI_OCT_2 7150=MI_OCT_3 7151=MI_OCT_4
        7152=MI_OCT_5 7153=MI_OCT_6 7154=MI_OCT_7 7155=MI_OCTD 7156=MI_OCTU 7157=MI_TRNS_N6 7158=MI_TRNS_N5
        7159=MI_TRNS_N4 715A=MI_TRNS_N3 715B=MI_TRNS_N2 715C=MI_TRNS_N1 715D=MI_TRNS_0 715E=MI_TRNS_1 715F=MI_TRNS_2
        7160=MI_TRNS_3 7161=MI_TRNS_4 7162=MI_TRNS_5 7163=MI_TRNS_6 7164=MI_TRNSD 7165=MI_TRNSU 7167=MI_VEL_1
        7168=MI_VEL_2 7169=MI_VEL_3 716A=MI_VEL_4 716B=MI_VEL_5 716C=MI_VEL_6 716D=MI_VEL_7 716E=MI_VEL_8 716F=MI_VEL_9
        7170=MI_VEL_10 7171=MI_VELD 7172=MI_VELU 7173=MI_CH1 7174=MI_CH2 7175=MI_CH3 7176=MI_CH4 7177=MI_CH5
        7178=MI_CH6 7179=MI_CH7 717A=MI_CH8 717B=MI_CH9 717C=MI_CH10 717D=MI_CH11 717E=MI_CH12 717F=MI_CH13
        7180=MI_CH14 7181=MI_CH15 7182=MI_CH16 7183=MI_CHD 7184=MI_CHU 7186=MI_SUS 7187=MI_PORT 7188=MI_SOST
        7189=MI_SOFT 718A=MI_LEG 718B=MI_MOD 718C=MI_MODSD 718D=MI_MODSU 718E=MI_BENDD 718F=MI_BENDU
        """
}
