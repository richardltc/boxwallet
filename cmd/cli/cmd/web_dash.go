package cmd

//func WebDash() htmx.RequestProcessor {
//		var data formData
//
//		// htmx.Paragraph ensures correct html encoding of characters. You can also use a htmx.CustomHtml component if more control is desired.
//		infomessage := &htmx.Paragraph{
//			Text: "This version currently discards not-validated input.",
//		}
//
//		thankyoumessage := &htmx.Paragraph{
//			Hidden: true,
//			Text:   "Thank you for submitting your data.",
//		}
//
//		form := &htmx.Form{
//			ID:          "signupform",
//			ButtonTitle: "Sign up",
//			Container: &htmx.Panel{
//				Controls: []htmx.HtmlBuilder{
//					&htmxc.LabelEdit{
//						Caption:   "Name",
//						FieldName: "name",
//						Editor: &htmxc.GEditString{
//							Length:    60,
//							MaxLength: 60,
//							StringRef: &data.name,
//						},
//					},
//					&htmxc.LabelEdit{
//						Caption:   "E-mail",
//						FieldName: "email",
//						Editor: &htmxc.GEditString{
//							Length:     40,
//							MaxLength:  50,
//							StringRef:  &data.email,
//							OnValidate: validateEmail,
//						},
//					},
//					&htmxc.LabelEdit{
//						Caption:   "Phone number",
//						FieldName: "phone",
//						ExtraInfo: "Adding a national prefix is optional",
//						Editor: &htmxc.GEditString{
//							Length:     30,
//							MaxLength:  30,
//							StringRef:  &data.phone,
//							OnValidate: validatePhone,
//						},
//					},
//					&htmxc.LabelEdit{
//						Caption:   "Signup Type",
//						FieldName: "signuptype",
//						Editor: &htmxc.GEditSelect{
//							ZeroIsInvalid:   true,
//							AskUserToSelect: true,
//							Representations: map[int]string{
//								1: "Consumer",
//								2: "Business",
//							},
//							IntRef: &data.signuptype,
//						},
//					},
//				},
//			},
//			OnLoadData: func(form *htmx.Form, ctx *htmx.Context) error {
//				// This is where can be loaded from a database
//				data = formData{
//					name: "Simulated data from a database",
//				}
//				return nil
//			},
//			OnIncoming: func(form *htmx.Form, ctx *htmx.Context) error {
//				// This is called only if everything validates, and where the user input will be saved to a database.
//				form.Hidden = true
//				thankyoumessage.Hidden = false
//				// If saving to database fails, error can be returned to show to the end-user.
//				return nil
//			},
//		}
//
//		page := &htmx.Panel{
//			Controls: []htmx.HtmlBuilder{
//				&htmx.Heading1{Text: `Signup form`},
//				infomessage,
//				form,
//				thankyoumessage,
//			},
//		}
//	return page
//	//
//}
